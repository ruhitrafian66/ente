const int searchTabIndex = 3;

// Tab events keep stable IDs: Search remains 3. ID 2 was the Feed tab, which
// the offline fork does not have.
List<int> homeTabIndices() => [0, 1, searchTabIndex];
