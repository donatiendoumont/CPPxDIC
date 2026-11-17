/**
 * @file test_trial_selection.cpp
 * @brief Unit tests for readSubjectTrialCsv (include/trial_selection.h): the plain
 *        "subject,trial" format and the optional per-trial frame window columns
 *        (start,end,jump). Header-only code under test: no production library needed.
 */

#include "../framework/test_harness.h"
#include "trial_selection.h"

#include <cstdio>
#include <fstream>
#include <string>

using cppxdic::readSubjectTrialCsv;
using cppxdic::SubjectTrial;

namespace {

/// Write `content` to a scratch file in the current directory, parse it, delete it.
/// Throws whatever readSubjectTrialCsv throws (file is removed in all cases).
std::vector<SubjectTrial> parse(const std::string& content) {
    static int counter = 0;
    const std::string path = "trial_selection_test_" + std::to_string(++counter) + ".csv";
    {
        std::ofstream out(path, std::ios::binary);
        out << content;
    }
    struct Cleanup {
        std::string p;
        ~Cleanup() { std::remove(p.c_str()); }
    } cleanup{path};
    return readSubjectTrialCsv(path);
}

bool parse_throws(const std::string& content) {
    try {
        parse(content);
    } catch (const std::exception&) {
        return true;
    }
    return false;
}

} // namespace

TEST(trial_selection, plain_two_columns_has_no_window) {
    auto rows = parse("subject,trial\nDD4_rolling,2\nNC_rolling,3\n");
    REQUIRE_TRUE(rows.size() == 2);
    CHECK_EQ(rows[0].subject, std::string("DD4_rolling"));
    CHECK_EQ(rows[0].trial, 2);
    CHECK_EQ(rows[1].subject, std::string("NC_rolling"));
    CHECK_EQ(rows[1].trial, 3);
    CHECK_FALSE(rows[0].hasWindow());
    CHECK_FALSE(rows[1].hasWindow());
}

TEST(trial_selection, full_window_columns) {
    auto rows = parse("subject,trial,start,end,jump\nDD4_rolling,2,20,140,2\n");
    REQUIRE_TRUE(rows.size() == 1);
    CHECK_TRUE(rows[0].hasWindow());
    REQUIRE_TRUE(rows[0].start.has_value());
    REQUIRE_TRUE(rows[0].end.has_value());
    REQUIRE_TRUE(rows[0].jump.has_value());
    CHECK_EQ(*rows[0].start, 20);
    CHECK_EQ(*rows[0].end, 140);
    CHECK_EQ(*rows[0].jump, 2);
}

TEST(trial_selection, empty_fields_stay_unset_so_config_applies) {
    // Row 1: all three empty. Row 2: only start+jump. Row 3: trailing columns absent.
    auto rows = parse("subject,trial,start,end,jump\n"
                      "DD4_rolling,3,,,\n"
                      "NC_rolling,2,15,,2\n"
                      "NC_rolling,3,10\n");
    REQUIRE_TRUE(rows.size() == 3);

    CHECK_FALSE(rows[0].hasWindow());

    CHECK_TRUE(rows[1].start.has_value());
    CHECK_FALSE(rows[1].end.has_value());
    CHECK_TRUE(rows[1].jump.has_value());
    CHECK_EQ(*rows[1].start, 15);
    CHECK_EQ(*rows[1].jump, 2);

    CHECK_TRUE(rows[2].start.has_value());
    CHECK_FALSE(rows[2].end.has_value());
    CHECK_FALSE(rows[2].jump.has_value());
    CHECK_EQ(*rows[2].start, 10);
}

TEST(trial_selection, donatien_example_csv_with_config_column_names) {
    // Header names are not interpreted (positional columns); empty cells keep dic_params.txt.
    auto rows = parse("subject,trial,idx_frame_start,idx_frame_end,frame_jump\n"
                      "DD4_rolling,2,16,161,1\n"
                      "DD4_rolling,3,16,161,1\n"
                      "NC_rolling,2,,,\n"
                      "NC_rolling,3,\n"
                      "NC_rolling,4\n");
    REQUIRE_TRUE(rows.size() == 5);
    CHECK_EQ(*rows[0].start, 16);
    CHECK_EQ(*rows[0].end, 161);
    CHECK_EQ(*rows[0].jump, 1);
    CHECK_EQ(*rows[1].start, 16);
    CHECK_FALSE(rows[2].hasWindow());
    CHECK_FALSE(rows[3].hasWindow());  // trailing comma only
    CHECK_FALSE(rows[4].hasWindow());  // no extra columns
    CHECK_EQ(rows[4].trial, 4);
}

TEST(trial_selection, end_zero_means_end_of_video_and_is_accepted) {
    auto rows = parse("subject,trial,start,end,jump\nS1,1,5,0,1\n");
    REQUIRE_TRUE(rows.size() == 1);
    REQUIRE_TRUE(rows[0].end.has_value());
    CHECK_EQ(*rows[0].end, 0);
}

TEST(trial_selection, whitespace_crlf_comments_and_blank_lines) {
    auto rows = parse("subject,trial,start,end,jump\r\n"
                      "# a comment\r\n"
                      "\r\n"
                      " S1 , 4 , 12 , 90 , 3 \r\n");
    REQUIRE_TRUE(rows.size() == 1);
    CHECK_EQ(rows[0].subject, std::string("S1"));
    CHECK_EQ(rows[0].trial, 4);
    CHECK_EQ(*rows[0].start, 12);
    CHECK_EQ(*rows[0].end, 90);
    CHECK_EQ(*rows[0].jump, 3);
}

TEST(trial_selection, invalid_windows_are_rejected) {
    CHECK_TRUE(parse_throws("subject,trial,start,end,jump\nS1,1,0,50,1\n"));    // start < 1
    CHECK_TRUE(parse_throws("subject,trial,start,end,jump\nS1,1,10,50,0\n"));   // jump < 1
    CHECK_TRUE(parse_throws("subject,trial,start,end,jump\nS1,1,60,50,1\n"));   // end < start
    CHECK_TRUE(parse_throws("subject,trial,start,end,jump\nS1,1,10,-5,1\n"));   // end < 0
    CHECK_TRUE(parse_throws("subject,trial,start,end,jump\nS1,1,abc,50,1\n"));  // not a number
    CHECK_TRUE(parse_throws("subject,trial,start,end,jump\nS1,1,10x,50,1\n"));  // trailing junk
}

TEST(trial_selection, missing_trial_field_is_rejected) {
    CHECK_TRUE(parse_throws("subject,trial\nS1\n"));
}

TEST_MAIN()
