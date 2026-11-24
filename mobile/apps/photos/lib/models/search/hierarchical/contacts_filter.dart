import "package:ente_components/hugeicons.dart";
import "package:photos/extensions/user_extension.dart";
import "package:photos/models/api/collection/user.dart";
import "package:photos/models/file/file.dart";
import "package:photos/models/search/hierarchical/hierarchical_search_filter.dart";
import "package:photos/utils/contact_string_util.dart";

class ContactsFilter extends HierarchicalSearchFilter {
  final User user;
  final int occurrence;
  final String? filterName;

  ContactsFilter({
    required this.user,
    required this.occurrence,
    this.filterName,
    super.filterTypeName = "contactsFilter",
    super.matchedUploadedIDs,
  });

  @override
  String name() {
    // Offline fork: there are no saved Ente contacts. Use the linked person
    // name or label, then the known email.
    return filterName ??
        trimToNull(user.displayName) ??
        knownContactEmailOrNull(user.email) ??
        "Someone";
  }

  @override
  int relevance() {
    return occurrence;
  }

  @override
  bool isMatch(EnteFile file) {
    return file.ownerID == user.id;
  }

  @override
  bool isSameFilter(HierarchicalSearchFilter other) {
    if (other is ContactsFilter) {
      return other.user.id == user.id;
    }
    return false;
  }

  @override
  SearchFilterIcon icon() {
    return HugeIcons.strokeRoundedUser;
  }
}
