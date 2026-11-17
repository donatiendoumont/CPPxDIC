/**
 * @file mirrored_mode.cpp
 * @brief Implementation of the mirrored-camera xDIC mode ("MNG" variant).
 *
 * Compiled into `cppxdic` only when configured with `-DXDIC_MODE=mirrored`
 * (which defines XDIC_MODE_MIRRORED). See include/xdic/mirrored/mirrored_mode.h.
 *
 * Pipeline (mirror of stepD_2DDIC_MNG.m):
 *   1. For each stereopair, resolve its two logical views via the MNG geometry
 *      (get_cam_view_stereopair_param.m + camera_info_from_view.m).
 *   2. Mask-extract each view as a stand-alone full frame from the single physical-camera
 *      video (import_raw_vid_MNG.m: temp(:, mask_nbr, :)). This is the missing C++ part.
 *   3. Saturate (satur.m), bandpass-filter (filter_like_ben.m, when im_filter_mode) and
 *      run standard 2D DIC on the extracted views, reusing the CppNCorr engine, ROIManager
 *      and StepDWorkflow helpers exactly as the camerapairs path does:
 *        - view1 -> view2 matching at the reference frame (step1_2),
 *        - map the view1 ROI/seed through the matching field to seed view2,
 *        - temporal tracking of view1 (step1) and view2 (step2).
 *   4. Persist the per-view ncorr outputs (.bin) and format them into
 *      myDIC2DpairResults (step2_dic_finish.m) under the per-trial/per-pair output dir.
 */

#include "xdic/mirrored/mirrored_mode.h"

#include "config.h"
#include "parameters.h"
#include "utils.h"
#include "image_processor.h"
#include "roi_manager.h"
#include "step_d_workflow.h"
#include "mat_writer.h"
#include "logging.h"

#include <ncorr.h>
#include <opencv2/opencv.hpp>

#include <algorithm>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <regex>
#include <sstream>
#include <string>
#include <vector>

namespace xdic {
namespace mirrored {

namespace {

namespace fs = std::filesystem;

// MATLAB stepD_2DDIC_MNG.m constants.
constexpr int kMngFps = 50;          // theGlobalSettings_MNG.actual_FS_vid
constexpr int kLimitGrayscale = 120; // LIMIT_GRAYSCALE

// Default physical-camera ordering from theGlobalSettings_MNG.cam_order = [2 1 4 3],
// used only if the config supplies an empty mirrored_cam_order.
const std::vector<int> kDefaultCamOrder = {2, 1, 4, 3};

bool ensureDir(const std::string& path) {
    try {
        if (!fs::exists(path)) {
            return fs::create_directories(path);
        }
        return true;
    } catch (...) {
        return false;
    }
}

std::string padNumber(int num, int width) {
    std::ostringstream oss;
    oss << std::setw(width) << std::setfill('0') << num;
    return oss.str();
}

// Locate the single physical-camera video for a trial.
//
// MATLAB import_raw_vid_MNG.m matches: <expID>_<unitID>_<trial>_*_cam_<id>.mp4 .
// The C++ camerapairs convention (find_video_file in utils.cpp) is
// <subject>_<material>_speckles_<trial>_.*_cam_<id>.*.mp4 . We accept either, plus a
// permissive fallback that just requires "_cam_<id>" before the .mp4 extension, so the
// mode works across both the MNG raw naming and the speckle naming.
std::string findCameraVideo(const std::string& video_dir, const std::string& subject,
                            const std::string& material, const std::string& trialname, int cam_id) {
    if (!fs::exists(video_dir)) return "";

    const std::regex pat_speckle(subject + "_" + material + "_speckles_" + trialname + "_.*_cam_" +
                                 std::to_string(cam_id) + ".*\\.mp4$");
    const std::regex pat_mng(subject + "_.*_" + trialname + "_.*_cam_" + std::to_string(cam_id) +
                             ".*\\.mp4$");
    const std::regex pat_loose(".*_cam_" + std::to_string(cam_id) + "(\\.|_).*\\.mp4$");
    const std::regex pat_loose_end(".*_cam_" + std::to_string(cam_id) + "\\.mp4$");

    std::string loose_match;
    for (const auto& entry : fs::directory_iterator(video_dir)) {
        if (!entry.is_regular_file()) continue;
        const std::string name = entry.path().filename().string();
        if (std::regex_match(name, pat_speckle) || std::regex_match(name, pat_mng)) {
            return entry.path().string();
        }
        if (loose_match.empty() &&
            (std::regex_match(name, pat_loose) || std::regex_match(name, pat_loose_end))) {
            // Only accept the loose fallback if the trial token appears in the name.
            if (name.find(trialname) != std::string::npos) {
                loose_match = entry.path().string();
            }
        }
    }
    return loose_match;
}

// Convert a decoded frame to the single-channel "grayscale" plane MATLAB uses
// (iloc(:,:,1) -> red channel). Mirrors importRawVid in utils.cpp.
cv::Mat toGrayPlane(const cv::Mat& frame) {
    if (frame.channels() == 3) {
        std::vector<cv::Mat> ch;
        cv::split(frame, ch);
        return ch[2]; // R channel (BGR -> index 2)
    }
    return frame;
}

} // namespace

ViewPair resolveViewPair(int stereopair, const std::vector<int>& cam_order) {
    // Port of get_cam_view_stereopair_param.m: stereopair -> (view_nbr_1, view_nbr_2).
    int v1 = 0, v2 = 0;
    switch (stereopair) {
        case 1:
            v1 = 1;
            v2 = 2;
            break;
        case 2:
            v1 = 2;
            v2 = 3;
            break;
        case 3:
            v1 = 3;
            v2 = 4;
            break;
        case 4:
            v1 = 4;
            v2 = 5;
            break;
        case 5:
            v1 = 6;
            v2 = 5;
            break;
        case 6:
            v1 = 7;
            v2 = 6;
            break;
        case 7:
            v1 = 8;
            v2 = 7;
            break;
        default:
            throw std::runtime_error("mirrored: invalid stereopair " + std::to_string(stereopair));
    }

    // Port of camera_info_from_view.m: view_nbr -> (cam_nbr via cam_order, half).
    auto info_from_view = [&cam_order](int view_nbr) -> ViewInfo {
        ViewInfo vi;
        vi.view_nbr = view_nbr;
        // views 1,2 -> cam_order[0]; 3,4 -> cam_order[1]; 5,6 -> cam_order[2]; 7,8 -> cam_order[3]
        const int cam_slot = (view_nbr - 1) / 2; // 0..3
        if (cam_slot < 0 || cam_slot >= static_cast<int>(cam_order.size())) {
            throw std::runtime_error("mirrored: view " + std::to_string(view_nbr) +
                                     " has no camera in cam_order");
        }
        vi.cam_nbr = cam_order[cam_slot];
        // odd view_nbr -> left half (mask 1), even view_nbr -> right half (mask 2)
        vi.half = (view_nbr % 2 == 1) ? MaskHalf::Left : MaskHalf::Right;
        return vi;
    };

    ViewPair vp;
    vp.stereopair = stereopair;
    vp.view1 = info_from_view(v1);
    vp.view2 = info_from_view(v2);
    return vp;
}

cv::Mat extractViewFromFrame(const cv::Mat& frame, MaskHalf half) {
    const cv::Mat gray = toGrayPlane(frame);
    const int w = gray.cols;
    const int half_w = w / 2;
    // MATLAB im_mask_width{1} = 1:W/2 ; {2} = W/2+1:W
    if (half == MaskHalf::Left) {
        return gray(cv::Rect(0, 0, half_w, gray.rows)).clone();
    }
    return gray(cv::Rect(half_w, 0, w - half_w, gray.rows)).clone();
}

bool importRawViewMirrored(const Config& config, int trial, const ViewInfo& view, int frameStart,
                           int frameEnd, int frameJump, std::vector<std::string>& out_frames) {
    try {
        const std::string trialname = padNumber(trial, 3);
        const std::string video_dir = Utils::buildVideoDir(config, true, true, true, true);

        const std::string vid =
            findCameraVideo(video_dir, config.subject_id, config.material, trialname, view.cam_nbr);
        if (vid.empty()) {
            LOG_ERROR << "mirrored: video not found for trial=" << trial << " cam=" << view.cam_nbr
                      << " in " << video_dir;
            return false;
        }

        cv::VideoCapture cap(vid);
        if (!cap.isOpened()) {
            LOG_ERROR << "mirrored: failed to open video: " << vid;
            return false;
        }

        LOG_INFO << "  view " << view.view_nbr << " (cam " << view.cam_nbr << ", half "
                 << (view.half == MaskHalf::Left ? "L" : "R") << ") <- " << vid;

        const int total = static_cast<int>(cap.get(cv::CAP_PROP_FRAME_COUNT));
        if (frameEnd <= 0) frameEnd = total;
        frameStart = std::max(1, frameStart);
        frameEnd = std::min(frameEnd, total);
        if (frameJump <= 0) frameJump = 1;

        // Per-view frame output dir (kept separate from the camerapairs tmp_frames layout).
        // Views are shared between adjacent stereopairs (view 2 serves pairs 1 and 2), so
        // the extracted PNG sequence is cached per (trial, view) and reused when a
        // previous extraction with the same frame window completed.
        std::ostringstream odir;
        odir << config.dic_path << "/" << config.subject_id << "/" << config.material
             << "/tmp_frames_mirrored/T" << trial << "/view" << view.view_nbr;
        const std::string view_dir = odir.str();
        if (!ensureDir(view_dir)) {
            LOG_ERROR << "mirrored: cannot create frame dir " << view_dir;
            return false;
        }
        const std::string done_marker = view_dir + "/.extracted";
        std::ostringstream window_sig;
        window_sig << vid << " " << frameStart << " " << frameEnd << " " << frameJump;
        {
            std::ifstream marker(done_marker);
            std::string prev;
            if (marker && std::getline(marker, prev) && prev == window_sig.str()) {
                for (int f = frameStart; f <= frameEnd; f += frameJump) {
                    std::ostringstream fp;
                    fp << view_dir << "/frame_" << std::setw(6) << std::setfill('0') << f << ".png";
                    if (!fs::exists(fp.str())) { out_frames.clear(); break; }
                    out_frames.push_back(fp.str());
                }
                if (!out_frames.empty()) {
                    LOG_INFO << "  view " << view.view_nbr << ": reusing " << out_frames.size()
                             << " cached frames in " << view_dir;
                    return true;
                }
            }
        }
        fs::remove(done_marker);

        // Read sequentially instead of seeking before every frame. On the FFmpeg
        // backend (Linux) cap.set(CAP_PROP_POS_FRAMES, n) re-seeks to the previous
        // keyframe and re-decodes forward on every call, making import ~O(N * GOP).
        // Seek once to the start, then read forward; grab (decode without Mat
        // conversion) the frames skipped when frameJump > 1.
        if (frameStart > 1) {
            cap.set(cv::CAP_PROP_POS_FRAMES, frameStart - 1);
        }

        int cur = frameStart; // 1-based index of the frame the next read()/grab() yields
        bool eof = false;
        for (int f = frameStart; f <= frameEnd && !eof; f += frameJump) {
            while (cur < f) {
                if (!cap.grab()) { eof = true; break; }
                ++cur;
            }
            if (eof) break;

            cv::Mat raw;
            if (!cap.read(raw)) break;
            ++cur;
            const cv::Mat region = extractViewFromFrame(raw, view.half);

            std::ostringstream fp;
            fp << view_dir << "/frame_" << std::setw(6) << std::setfill('0') << f << ".png";
            cv::imwrite(fp.str(), region);
            out_frames.push_back(fp.str());
        }

        if (!out_frames.empty() && !eof) {
            std::ofstream marker(done_marker);
            marker << window_sig.str() << "\n";
        }
        return !out_frames.empty();
    } catch (const std::exception& e) {
        LOG_ERROR << "mirrored: importRawViewMirrored error: " << e.what();
        return false;
    }
}

namespace {

// Reuse the CppNCorr engine exactly like StepDWorkflow::runNcorrAnalysis: build Image2D
// from PNG paths, build ROI2D from the mask, run the MATLAB-style sequential DIC, then
// persist the raw (pixel) output. Returns the raw DIC output.
ncorr::DIC_analysis_output runViewDic(const Config& config, const cv::Mat& ref_img,
                                      const std::vector<cv::Mat>& cur_imgs, const cv::Mat& roi_mask,
                                      const cppxdic::SeedPoint& seed_point,
                                      const cppxdic::StepParameters& step_params,
                                      const std::string& tmp_dir, const std::string& output_path) {
    // Checkpoint: a completed DIC for this view/pair is reloaded instead of recomputed
    // (same convention as StepDWorkflow's ncorr{cam}.bin caches).
    if (fs::exists(output_path)) {
        LOG_INFO << "    Checkpoint found: " << output_path << " (loading)";
        return ncorr::DIC_analysis_output::load(output_path);
    }
    ensureDir(tmp_dir);

    std::vector<ncorr::Image2D> imgs;
    const std::string ref_path = tmp_dir + "/ref.png";
    cv::imwrite(ref_path, ref_img);
    imgs.emplace_back(ref_path);
    for (std::size_t i = 0; i < cur_imgs.size(); ++i) {
        std::ostringstream oss;
        oss << tmp_dir << "/cur_" << std::setw(4) << std::setfill('0') << i << ".png";
        cv::imwrite(oss.str(), cur_imgs[i]);
        imgs.emplace_back(oss.str());
    }

    ncorr::ROI2D roi = cppxdic::ROIManager::matToNcorrROI(roi_mask);

    const int scalefactor = step_params.spacing + 1;
    ncorr::DIC_analysis_input dic_input(
        imgs, roi, scalefactor, ncorr::INTERP::QUINTIC_BSPLINE_PRECOMPUTE, ncorr::SUBREGION::CIRCLE,
        step_params.radius, step_params.total_threads,
        config.ncorr_no_update ? ncorr::DIC_analysis_config::NO_UPDATE
                               : ncorr::DIC_analysis_config::KEEP_MOST_POINTS,
        config.debug_mode);
    dic_input.update_corrcoef = config.ncorr_cutoff_corrcoef;

    // Same engine configuration as StepDWorkflow::runNcorrAnalysis: seeds, fixed-step
    // reference updates and the seed-quality gates come from ncorr_params.txt. The
    // view1->view2 MATCHING call (<= 2 current images) uses the looser matching gate:
    // two mirror views see the fingertip under different perspectives and the seed
    // converges around corrcoef 0.5, which the tracking gate rejects.
    const bool is_matching = cur_imgs.size() <= 2;
    ncorr::DIC_analysis_parallel_input in(
        dic_input, {ncorr::SeedParams(seed_point.pw[0], seed_point.pw[1])},
        config.ncorr_seeds_are_optimized);
    in.fixed_step_ref = config.ncorr_fixed_step_ref;
    in.cutoff_max_diffnorm = config.ncorr_cutoff_max_diffnorm;
    in.cutoff_max_corrcoef = is_matching ? config.ncorr_matching_cutoff_max_corrcoef
                                         : config.ncorr_cutoff_max_corrcoef;
    LOG_INFO << "    ncorr " << (is_matching ? "matching" : "tracking") << ": "
             << cur_imgs.size() << " frame(s), radius " << step_params.radius << ", threads "
             << step_params.total_threads << ", seed (" << seed_point.pw[0] << ","
             << seed_point.pw[1] << "), seed gate corrcoef<=" << in.cutoff_max_corrcoef
             << (config.parallel_processing && !is_matching ? " [parallel]" : " [sequential]");

    ncorr::DIC_analysis_output dic_out;
    if (config.parallel_processing && !is_matching) {
        dic_out = config.ncorr_use_exact_matlab ? ncorr::exact_matlab_DIC_analysis_parallel(in)
                                                : ncorr::matlab_DIC_analysis_parallel(in);
    } else {
        dic_out = config.ncorr_use_exact_matlab ? ncorr::exact_matlab_DIC_analysis_sequential(in)
                                                : ncorr::matlab_DIC_analysis_sequential(in);
    }

    // Persist the raw (pixel) displacements, matching StepDWorkflow's convention.
    // `save` is a friend free function found via ADL on the ncorr argument type.
    save(dic_out, output_path);
    LOG_INFO << "    DIC saved: " << output_path;
    return dic_out;
}

// ---- Visual check of the view1 -> view2 matching ---------------------------------------

// BGR copy of `img` where everything outside `roi_mask` is divided by 4.
cv::Mat dimOutsideRoi(const cv::Mat& img, const cv::Mat& roi_mask) {
    cv::Mat g8;
    if (img.depth() == CV_8U) {
        g8 = img.clone();
    } else {
        double mn = 0.0, mx = 0.0;
        cv::minMaxLoc(img, &mn, &mx);
        img.convertTo(g8, CV_8U, (mx <= 1.0) ? 255.0 : 1.0);
    }
    if (g8.channels() == 3) cv::cvtColor(g8, g8, cv::COLOR_BGR2GRAY);
    cv::Mat dim;
    g8.convertTo(dim, CV_8U, 0.25);
    if (!roi_mask.empty() && roi_mask.size() == g8.size() && roi_mask.channels() == 1) {
        const cv::Mat inside = roi_mask > 0;
        g8.copyTo(dim, inside); // same brightness inside the ROI
    }
    cv::Mat bgr;
    cv::cvtColor(dim, bgr, cv::COLOR_GRAY2BGR);
    return bgr;
}

// Thin (1 px) green ROI outline.
void drawRoiOutline(cv::Mat& bgr, const cv::Mat& roi_mask) {
    if (roi_mask.empty() || roi_mask.size() != bgr.size() || roi_mask.channels() != 1) return;
    cv::Mat inside = roi_mask > 0;
    std::vector<std::vector<cv::Point>> contours;
    cv::findContours(inside, contours, cv::RETR_LIST, cv::CHAIN_APPROX_NONE);
    cv::drawContours(bgr, contours, -1, cv::Scalar(0, 255, 0), 1, cv::LINE_8);
}

// One PNG per pair: [ref | cur] side by side, brightness /4 outside each ROI, ROI outline,
// red seed dot, subset circle (radius `radius`) around the seed in the reference view and
// the same circle transported by the matching displacement field in the current view
// (cyan cross = exact transported centre; red dot = seed2 actually used, rounded to the
// subset grid). A caption strip below gives subject / trial / pair / view numbers.
// Purely a visualisation: it never changes any result and never throws.
void saveMatchCheckImage(const Config& config, int trial, const ViewPair& vp,
                         const cv::Mat& ref_img, const cv::Mat& cur_img, const cv::Mat& roi_ref,
                         const cv::Mat& roi_cur, const cppxdic::SeedPoint& seed_ref,
                         const cppxdic::SeedPoint& seed_cur,
                         const ncorr::DIC_analysis_output& dic12, int radius,
                         const std::string& out_path) {
    try {
        cv::Mat left = dimOutsideRoi(ref_img, roi_ref);
        cv::Mat right = dimOutsideRoi(cur_img, roi_cur);
        if (right.size() != left.size()) cv::resize(right, right, left.size());
        drawRoiOutline(left, roi_ref);
        drawRoiOutline(right, roi_cur);

        const cv::Scalar kRed(0, 0, 255), kYellow(0, 255, 255), kCyan(255, 255, 0);
        int n_fallback = 0;

        if (!dic12.disps.empty() && seed_ref.pw.size() == 2) {
            const auto& disp = dic12.disps.front();
            const auto& u_data = disp.get_u();
            const auto& v_data = disp.get_v();
            const auto& u_array = u_data.get_array();
            const auto& v_array = v_data.get_array();
            const double scale = static_cast<double>(disp.get_scalefactor());
            const int gw = static_cast<int>(u_data.data_width());
            const int gh = static_cast<int>(u_data.data_height());
            const auto& valid = disp.get_roi().get_mask();
            auto gridOk = [&](int gx, int gy) {
                if (gx < 0 || gy < 0 || gx >= gw || gy >= gh) return false;
                return static_cast<bool>(valid(gy, gx)) && std::isfinite(u_array(gy, gx)) &&
                       std::isfinite(v_array(gy, gx));
            };
            // Bilinear (u, v) in pixels at pixel (px, py); grid point g <-> pixel g * scale.
            auto sample = [&](double px, double py, double& u, double& v) {
                const double gx = px / scale, gy = py / scale;
                const int x0 = static_cast<int>(std::floor(gx));
                const int y0 = static_cast<int>(std::floor(gy));
                if (!(gridOk(x0, y0) && gridOk(x0 + 1, y0) && gridOk(x0, y0 + 1) &&
                      gridOk(x0 + 1, y0 + 1)))
                    return false;
                const double fx = gx - x0, fy = gy - y0;
                auto lerp = [&](const auto& a) {
                    return (1 - fx) * (1 - fy) * a(y0, x0) + fx * (1 - fy) * a(y0, x0 + 1) +
                           (1 - fx) * fy * a(y0 + 1, x0) + fx * fy * a(y0 + 1, x0 + 1);
                };
                u = lerp(u_array);
                v = lerp(v_array);
                return true;
            };

            // Centre: the seed itself when the field is valid there, else the valid grid
            // point nearest to it.
            double cx = seed_ref.pw[0], cy = seed_ref.pw[1];
            int sgx = static_cast<int>(std::lround(cx / scale));
            int sgy = static_cast<int>(std::lround(cy / scale));
            if (!gridOk(sgx, sgy)) {
                double best = 1e300;
                int bx = -1, by = -1;
                for (int gy = 0; gy < gh; ++gy)
                    for (int gx = 0; gx < gw; ++gx)
                        if (gridOk(gx, gy)) {
                            const double d = (gx * scale - cx) * (gx * scale - cx) +
                                             (gy * scale - cy) * (gy * scale - cy);
                            if (d < best) { best = d; bx = gx; by = gy; }
                        }
                if (bx >= 0) { sgx = bx; sgy = by; cx = bx * scale; cy = by * scale; }
            }
            double uc = 0.0, vc = 0.0;
            bool have_center = sample(cx, cy, uc, vc);
            if (!have_center && gridOk(sgx, sgy)) {
                uc = u_array(sgy, sgx);
                vc = v_array(sgy, sgx);
                have_center = true;
            }

            // Subset circle in the reference view, and its image through the field.
            std::vector<cv::Point> ring_ref, ring_cur;
            for (int k = 0; k < 72; ++k) {
                const double t = 2.0 * CV_PI * k / 72.0;
                const double px = cx + radius * std::cos(t);
                const double py = cy + radius * std::sin(t);
                double u = uc, v = vc;
                if (!sample(px, py, u, v)) { ++n_fallback; u = uc; v = vc; }
                ring_ref.emplace_back(cvRound(px), cvRound(py));
                ring_cur.emplace_back(cvRound(px + u), cvRound(py + v));
            }
            cv::polylines(left, ring_ref, true, kYellow, 1, cv::LINE_AA);
            if (have_center) cv::polylines(right, ring_cur, true, kYellow, 1, cv::LINE_AA);
            cv::circle(left, cv::Point(cvRound(cx), cvRound(cy)), 4, kRed, cv::FILLED);
            if (have_center)
                cv::drawMarker(right, cv::Point(cvRound(cx + uc), cvRound(cy + vc)), kCyan,
                               cv::MARKER_CROSS, 12, 1);
        }
        if (seed_cur.pw.size() == 2)
            cv::circle(right, cv::Point(seed_cur.pw[0], seed_cur.pw[1]), 4, kRed, cv::FILLED);

        const cv::Scalar white(255, 255, 255);
        auto half = [](const ViewInfo& v) { return v.half == MaskHalf::Left ? "L" : "R"; };
        cv::putText(left, "ref view " + std::to_string(vp.view1.view_nbr), cv::Point(10, 24),
                    cv::FONT_HERSHEY_SIMPLEX, 0.7, white, 1, cv::LINE_AA);
        cv::putText(right, "cur view " + std::to_string(vp.view2.view_nbr), cv::Point(10, 24),
                    cv::FONT_HERSHEY_SIMPLEX, 0.7, white, 1, cv::LINE_AA);

        cv::Mat both, strip(64, left.cols * 2, CV_8UC3, cv::Scalar(0, 0, 0)), out;
        cv::hconcat(left, right, both);
        std::ostringstream l1, l2;
        l1 << "subject=" << config.subject_id << "  trial=" << padNumber(trial, 3)
           << "  pair=" << vp.stereopair << "  phase=" << config.phase_id;
        l2 << "ref = view " << vp.view1.view_nbr << " (cam " << vp.view1.cam_nbr << ", half "
           << half(vp.view1) << ")  |  cur = view " << vp.view2.view_nbr << " (cam "
           << vp.view2.cam_nbr << ", half " << half(vp.view2) << ")  |  subset radius "
           << radius << " px";
        cv::putText(strip, l1.str(), cv::Point(10, 24), cv::FONT_HERSHEY_SIMPLEX, 0.7, white, 1,
                    cv::LINE_AA);
        cv::putText(strip, l2.str(), cv::Point(10, 52), cv::FONT_HERSHEY_SIMPLEX, 0.7, white, 1,
                    cv::LINE_AA);
        cv::vconcat(both, strip, out);

        if (!cv::imwrite(out_path, out)) {
            LOG_WARN << "mirrored: could not write " << out_path;
            return;
        }
        LOG_INFO << "    Match check image: " << out_path
                 << (n_fallback ? " (" + std::to_string(n_fallback) +
                                      "/72 circle points outside the valid field: centre "
                                      "displacement used)"
                                : std::string());
    } catch (const std::exception& e) {
        LOG_WARN << "mirrored: match check image failed (" << e.what() << "); results unaffected";
    }
}

// Process one stereopair end-to-end for one trial.
bool processPair(const Config& config, int trial, const ViewPair& vp, int frameStart, int frameEnd,
                 int frameJump) {
    LOG_INFO << "--- Trial " << trial << " stereopair " << vp.stereopair << " (views "
             << vp.view1.view_nbr << " & " << vp.view2.view_nbr << ") ---";

    // 1. Mask-extract both views as full frames (import_raw_vid_MNG.m).
    std::vector<std::string> view1_paths, view2_paths;
    if (!importRawViewMirrored(config, trial, vp.view1, frameStart, frameEnd, frameJump,
                               view1_paths)) {
        LOG_ERROR << "mirrored: failed to extract view " << vp.view1.view_nbr;
        return false;
    }
    if (!importRawViewMirrored(config, trial, vp.view2, frameStart, frameEnd, frameJump,
                               view2_paths)) {
        LOG_ERROR << "mirrored: failed to extract view " << vp.view2.view_nbr;
        return false;
    }

    const std::size_t n = std::min(view1_paths.size(), view2_paths.size());
    if (n == 0) {
        LOG_ERROR << "mirrored: no frames extracted for pair " << vp.stereopair;
        return false;
    }

    // 2. Load + saturate (satur.m). LIMIT_GRAYSCALE is the MNG script constant (120)
    //    unless dic_params.txt sets limit_grayscale; im_saturation_mode=false skips the
    //    clipping entirely (pre-filtered videos).
    const int limit_grayscale = (config.limit_grayscale > 0) ? config.limit_grayscale : kLimitGrayscale;
    std::vector<cv::Mat> view1_satur, view2_satur;
    view1_satur.reserve(n);
    view2_satur.reserve(n);
    for (std::size_t i = 0; i < n; ++i) {
        cv::Mat a = cv::imread(view1_paths[i], cv::IMREAD_GRAYSCALE);
        cv::Mat b = cv::imread(view2_paths[i], cv::IMREAD_GRAYSCALE);
        if (a.empty() || b.empty()) {
            LOG_ERROR << "mirrored: failed to read extracted frame " << i;
            return false;
        }
        if (config.im_saturation_mode) {
            view1_satur.push_back(cppxdic::ImageProcessor::saturate(a, limit_grayscale, "high"));
            view2_satur.push_back(cppxdic::ImageProcessor::saturate(b, limit_grayscale, "high"));
        } else {
            view1_satur.push_back(a);
            view2_satur.push_back(b);
        }
    }
    LOG_INFO << (config.im_saturation_mode
                     ? "--> STEP : saturation done (limit_grayscale=" + std::to_string(limit_grayscale) + ")"
                     : std::string("--> STEP : saturation skipped (im_saturation_mode=false)"));

    // 3. Output layout (per trial / per pair), mirroring buildPath conventions.
    std::ostringstream odir;
    odir << config.dic_path << "/" << config.subject_id << "/" << config.material << "/"
         << padNumber(trial, 3) << "/" << config.phase_id << "/mirrored_pair" << vp.stereopair;
    const std::string out_dir = odir.str();
    ensureDir(out_dir);

    // 4. ROI: reuse ROIManager (loads REF mask if present, else full-frame ROI over view1).
    cppxdic::BaseParameters bp;
    bp.subject = config.subject_id;
    bp.material = config.material;
    bp.trial = padNumber(trial, 3);
    bp.stereopair = vp.stereopair;
    bp.phase = config.phase_id;
    bp.reftrial = padNumber(config.ref_trial_id, 3);
    bp.outputPath = out_dir;
    bp.baseResultPath = config.dic_path;
    bp.limit_grayscale = limit_grayscale;
    bp.roifile = Utils::buildRoiFilePath(bp, bp.reftrial, vp.stereopair);
    bp.seedfile = Utils::buildSeedFilePath(bp, bp.reftrial, vp.stereopair);

    cv::Mat roi_view1 = cppxdic::ROIManager::loadOrCreateROI(bp, view1_satur.front());

    // 5. DIC parameters (MNG values from stepD_2DDIC_MNG.m, overridable via config.step_d).
    cppxdic::StepParameters step_track;
    step_track.type = "regular";
    step_track.radius = (config.step_d.radius > 0) ? config.step_d.radius : 25;
    step_track.spacing = (config.step_d.spacing > 0) ? config.step_d.spacing : 20;
    step_track.cutoff_diffnorm = config.step_d.cutoff_diffnorm;
    step_track.cutoff_iteration = config.step_d.cutoff_iteration;
    step_track.total_threads = config.step_d.total_threads;
    step_track.stepanalysis_params.enabled = config.step_d.high_strain_enabled;
    step_track.stepanalysis_params.type = config.step_d.seed_type;
    step_track.stepanalysis_params.auto_update = config.step_d.auto_update;
    step_track.stepanalysis_params.step = config.step_d.step_ref_change;

    cppxdic::StepParameters step_match = step_track;
    step_match.radius =
        (config.step_e.radius > 0) ? config.step_e.radius : 30; // matching radius (MNG=30)

    // 6. Seed: reuse ROIManager (loads REF seed if present, else ROI centre), then map
    //    to subset world (map_pixel2subset.m) so the matching field can transport it.
    cppxdic::SeedPoint seed1 = cppxdic::ROIManager::loadOrCreateSeed(bp, roi_view1);
    seed1.sw = cppxdic::ROIManager::mapPixel2Subset(seed1.pw, step_track.spacing);

    // 7. Image filtering (filter_like_ben.m): gs bounds from view1 over the ROI, reused
    //    for view2 -- identical to StepDWorkflow::applyImageFiltering.
    std::vector<cv::Mat> view1, view2;
    if (config.im_filter_mode) {
        // param_filt_im and the normalisation percentiles come from dic_params.txt
        // (defaults 25,300 and 5,95 = the former hard-coded values).
        const std::vector<int>& param_filt = config.param_filt_im;
        const double p_lo = config.filt_percentiles[0];
        const double p_hi = config.filt_percentiles[1];
        auto [f1, gs_bounds] = cppxdic::ImageProcessor::filterLikeBen(
            view1_satur, roi_view1, param_filt, nullptr, p_lo, p_hi);
        auto [f2, _] = cppxdic::ImageProcessor::filterLikeBen(
            view2_satur, roi_view1, param_filt, &gs_bounds, p_lo, p_hi);
        view1 = std::move(f1);
        view2 = std::move(f2);
        LOG_INFO << "--> STEP : filtering done (param_filt_im=[" << param_filt[0] << ","
                 << param_filt[1] << "], percentiles=[" << p_lo << "," << p_hi << "])";
    } else {
        view1 = view1_satur;
        view2 = view2_satur;
        LOG_INFO << "--> STEP : raw (saturated) data used";
    }

    // 8. Trial info sidecar (dic_info_data_target_pair<N>.mat), as saveTrialInfo does.
    {
        std::vector<int> idxframe;
        for (int f = frameStart, k = 0; k < static_cast<int>(n); f += frameJump, ++k) {
            idxframe.push_back(f);
        }
        cppxdic::MatWriter::writeTrialInfoFile(
            out_dir + "/dic_info_data_target_pair" + std::to_string(vp.stereopair) + ".mat",
            static_cast<double>(kMngFps) / frameJump, idxframe);
    }

    // 9. MATCHING view1 -> view2 at the reference frame (input2 = [view2_1, view1_1]).
    //    Mirrors the ncorr_dic_rewrited matching call in stepD_2DDIC_MNG.m. The matching
    //    is done on the filtered frames, exactly like the MATLAB script (im_view_*).
    cv::Mat roi_view2_matched = roi_view1;
    cppxdic::SeedPoint seed2 = seed1;
    {
        std::vector<cv::Mat> match_cur = {view2.front(), view1.front()};
        const std::string match_out =
            Utils::buildNcorrFilePath(out_dir, vp.view1.view_nbr, vp.view2.view_nbr, ".bin");
        // Same fallback as StepDWorkflow::matchingInitialFrame: a seed near the ROI
        // boundary may not converge in the other view; retry once from the ROI centre.
        cppxdic::SeedPoint match_seed = seed1;
        ncorr::DIC_analysis_output dic12;
        try {
            dic12 = runViewDic(config, view1.front(), match_cur, roi_view1, match_seed, step_match,
                               out_dir + "/tmp_ncorr_match", match_out);
        } catch (const std::runtime_error& e) {
            const std::string what = e.what();
            if (what.find("could not seed") == std::string::npos) throw;
            const std::vector<int> c = cppxdic::ROIManager::findROICenter(roi_view1); // [x, y]
            match_seed = cppxdic::SeedPoint(c[0], c[1]);
            match_seed.sw = cppxdic::ROIManager::mapPixel2Subset(match_seed.pw, step_track.spacing);
            LOG_WARN << "mirrored: matching seed (" << seed1.pw[0] << "," << seed1.pw[1]
                     << ") did not converge in view " << vp.view2.view_nbr
                     << "; retrying from the ROI centre of mass (" << match_seed.pw[0] << ","
                     << match_seed.pw[1] << ")";
            dic12 = runViewDic(config, view1.front(), match_cur, roi_view1, match_seed, step_match,
                               out_dir + "/tmp_ncorr_match", match_out);
        }

        // Port of: refmask_trial_matched = h12.current(1).roi.mask;
        //          initial_seed_point_set2 = map_pointcoordinate(seed1.sw, {U,V}/(spacing+1))
        if (!cppxdic::StepDWorkflow::updateMaskAndSeedFromOutput(roi_view1, match_seed, dic12,
                                                                  roi_view2_matched, seed2)) {
            LOG_WARN << "mirrored: matching produced no displacement field; view2 will reuse "
                        "the view1 ROI/seed";
            roi_view2_matched = roi_view1;
            seed2 = seed1;
        }
        LOG_INFO << "--> STEP : Ncorr matching " << vp.view1.view_nbr << "-" << vp.view2.view_nbr
                 << " done (seed2=" << seed2.pw[0] << "," << seed2.pw[1] << ")";

        // Visual check of the matching (ref | cur with ROI, seed, subset circle).
        if (config.save_match_check_image) {
            saveMatchCheckImage(config, trial, vp, view1.front(), view2.front(), roi_view1,
                                roi_view2_matched, match_seed, seed2, dic12, step_match.radius,
                                out_dir + "/check_match_pair" + std::to_string(vp.stereopair) +
                                    ".png");
        }
    }

    // 10. TRACKING view1 across all frames (ncorr1).
    {
        const std::string track1_out =
            Utils::buildNcorrFilePath(out_dir, vp.view1.view_nbr, -1, ".bin");
        runViewDic(config, view1.front(), view1, roi_view1, seed1, step_track,
                   out_dir + "/tmp_ncorr_view1", track1_out);
        LOG_INFO << "--> STEP : Ncorr " << vp.view1.view_nbr << " done";
    }

    // 11. TRACKING view2 across frames 2..end (ncorr2), seeded/masked by the matching.
    {
        std::vector<cv::Mat> cur(view2.begin() + (view2.size() > 1 ? 1 : 0), view2.end());
        const std::string track2_out =
            Utils::buildNcorrFilePath(out_dir, vp.view2.view_nbr, -1, ".bin");
        runViewDic(config, view2.front(), cur, roi_view2_matched, seed2, step_track,
                   out_dir + "/tmp_ncorr_view2", track2_out);
        LOG_INFO << "--> STEP : Ncorr " << vp.view2.view_nbr << " done";
    }

    // 12. Format output (step2_dic_finish.m): ncorr{v1}.bin + ncorr{v2}.bin +
    //     ncorr{v1}{v2}.bin -> myDIC2DpairResults_C_{v1}_C_{v2}.<ext>. No protocol-driven
    //     pair order in the MNG script, so use the neutral default.
    cppxdic::StepDWorkflow::formatDic2DPairResults(config, step_track, out_dir, vp.view1.view_nbr,
                                                   vp.view2.view_nbr, {1, 2}, false);

    LOG_INFO << "--- pair " << vp.stereopair << " done; results in " << out_dir << " ---";
    return true;
}

} // namespace

bool run(const Config& config, const std::vector<int>& trials_in) {
    LOG_INFO << "-------------------------------------------";
    LOG_INFO << "xDIC mirrored-camera (MNG) mode";
    LOG_INFO << "-------------------------------------------";

    // Rig geometry from config (theGlobalSettings_MNG: Npair, cam_order).
    const int num_pair = config.mirrored_num_pair;
    const std::vector<int>& cam_order =
        config.mirrored_cam_order.empty() ? kDefaultCamOrder : config.mirrored_cam_order;
    if (num_pair <= 0) {
        LOG_ERROR << "mirrored: mirrored_num_pair must be > 0 (got " << num_pair << ")";
        return false;
    }

    // Frame range from config (import_vid_MNG honours frame_idx_set / protocol; here we
    // use the explicit config range, consistent with the camerapairs C++ path).
    const int frameStart = config.idx_frame_start;
    const int frameEnd = config.idx_frame_end;
    const int frameJump = (config.frame_jump > 0) ? config.frame_jump : 1;
    const double true_fps = static_cast<double>(kMngFps) / frameJump;
    std::ostringstream order_str;
    for (std::size_t i = 0; i < cam_order.size(); ++i) order_str << (i ? "," : "") << cam_order[i];
    LOG_INFO << "Stereopairs: " << num_pair << ", cam_order: [" << order_str.str() << "]";
    LOG_INFO << "True FPS: " << true_fps << ", frames " << frameStart << ".." << frameEnd
             << " jump " << frameJump;

    // Trials: the CLI selection (--trial/--trials/...) when given, else the reference
    // trial only (single-trial entry, as in the MATLAB script).
    std::vector<int> trials = trials_in;
    if (trials.empty()) trials.push_back(config.ref_trial_id);
    {
        std::ostringstream tl;
        for (std::size_t i = 0; i < trials.size(); ++i) tl << (i ? "," : "") << trials[i];
        LOG_INFO << "Trials: [" << tl.str() << "], reference trial " << config.ref_trial_id;
    }

    // Pairs to run: config.mirrored_pairs when set (validated), else all 1..num_pair.
    std::vector<int> pairs_to_run;
    for (int p : config.mirrored_pairs) {
        if (p < 1 || p > num_pair) {
            LOG_ERROR << "mirrored: mirrored_pairs contains " << p << ", outside 1.." << num_pair;
            return false;
        }
        if (std::find(pairs_to_run.begin(), pairs_to_run.end(), p) == pairs_to_run.end())
            pairs_to_run.push_back(p);
    }
    if (pairs_to_run.empty()) {
        for (int p = 1; p <= num_pair; ++p) pairs_to_run.push_back(p);
    }
    {
        std::ostringstream pl;
        for (std::size_t i = 0; i < pairs_to_run.size(); ++i) pl << (i ? "," : "") << pairs_to_run[i];
        LOG_INFO << "Pairs: [" << pl.str() << "]";
    }

    bool all_ok = true;
    for (int trial : trials) {
        for (int pair : pairs_to_run) {
            ViewPair vp;
            try {
                vp = resolveViewPair(pair, cam_order);
            } catch (const std::exception& e) {
                LOG_ERROR << "mirrored: " << e.what() << " (skipping pair " << pair << ")";
                all_ok = false;
                continue;
            }
            // One pair's failure (including engine exceptions such as "could not seed any
            // current image") must not abort the remaining pairs/trials.
            bool ok = false;
            try {
                ok = processPair(config, trial, vp, frameStart, frameEnd, frameJump);
            } catch (const std::exception& e) {
                LOG_ERROR << "mirrored: trial " << trial << " pair " << pair << " threw: " << e.what();
            }
            if (!ok) {
                LOG_ERROR << "mirrored: trial " << trial << " pair " << pair << " failed";
                all_ok = false;
            }
        }
    }

    if (all_ok) {
        LOG_INFO << "Mirrored-camera analysis completed.";
    } else {
        LOG_ERROR << "Mirrored-camera analysis completed with errors.";
    }
    return all_ok;
}

} // namespace mirrored
} // namespace xdic
