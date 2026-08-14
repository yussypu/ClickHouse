#include <gtest/gtest.h>

#include <IO/ReadBufferFromString.h>
#include <Storages/MergeTree/MergeTreeDataFormatVersion.h>
#include <Storages/MergeTree/ReplicatedMergeTreeLogEntry.h>

using namespace DB;

namespace
{

ReplicatedMergeTreeLogEntryData parseEntry(const String & text)
{
    ReplicatedMergeTreeLogEntryData entry;
    ReadBufferFromString in(text);
    entry.readText(in, MERGE_TREE_DATA_MIN_FORMAT_VERSION_WITH_CUSTOM_PARTITIONING);
    return entry;
}

ReplicatedMergeTreeLogEntryData makeMergeEntry(MergeType merge_type)
{
    ReplicatedMergeTreeLogEntryData entry;
    entry.type = ReplicatedMergeTreeLogEntryData::MERGE_PARTS;
    entry.source_replica = "r1";
    entry.source_parts = {"all_0_0_0", "all_1_1_0"};
    entry.new_part_name = "all_0_1_1";
    entry.create_time = 1723507200;
    entry.merge_type = merge_type;
    return entry;
}

}

TEST(ReplicatedMergeTreeLogEntry, CleanupMergeTypeRoundTrip)
{
    const auto text = makeMergeEntry(MergeType::Cleanup).toString();

    EXPECT_NE(text.find("merge_type: 5"), String::npos);
    EXPECT_EQ(text.find("cleanup"), String::npos);

    EXPECT_EQ(parseEntry(text).merge_type, MergeType::Cleanup);
}

TEST(ReplicatedMergeTreeLogEntry, RegularMergeHasNoMergeTypeField)
{
    const auto text = makeMergeEntry(MergeType::Regular).toString();

    EXPECT_EQ(text.find("merge_type"), String::npos);
    EXPECT_EQ(text.find("cleanup"), String::npos);

    EXPECT_EQ(parseEntry(text).merge_type, MergeType::Regular);
}

TEST(ReplicatedMergeTreeLogEntry, LegacyCleanupFlagUpgradesMergeType)
{
    const String text =
        "format version: 4\n"
        "create_time: 2024-01-01 00:00:00\n"
        "source replica: r1\n"
        "block_id: \n"
        "merge\n"
        "all_0_0_0\n"
        "all_1_1_0\n"
        "into\n"
        "all_0_1_1\n"
        "deduplicate: 0\n"
        "cleanup: 1\n";

    EXPECT_EQ(parseEntry(text).merge_type, MergeType::Cleanup);
}
