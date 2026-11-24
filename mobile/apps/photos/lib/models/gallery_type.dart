enum GalleryType {
  homepage,
  archive,
  uncategorized,
  // Files from every default-hidden collection.
  hiddenSection,
  hiddenOwnedCollection,
  favorite,
  trash,
  deleteSuggestions,
  localFolder,
  sharedCollection,
  ownedCollection,
  searchResults,
  locationTag,
  quickLink,
  peopleTag,
  cluster,
  sharedPublicCollection,
  magic,
  cleanupHiddenFromDevice,
}

extension GalleyTypeExtension on GalleryType {
  bool showDeleteIconOption() {
    switch (this) {
      case GalleryType.ownedCollection:
      case GalleryType.searchResults:
      case GalleryType.homepage:
      case GalleryType.favorite:
      case GalleryType.localFolder:
      case GalleryType.uncategorized:
      case GalleryType.locationTag:
      case GalleryType.quickLink:
      case GalleryType.peopleTag:
      case GalleryType.cluster:
      case GalleryType.magic:
        return true;
      case GalleryType.trash:
      case GalleryType.archive:
      case GalleryType.hiddenSection:
      case GalleryType.hiddenOwnedCollection:
      case GalleryType.sharedCollection:
      case GalleryType.sharedPublicCollection:
      case GalleryType.deleteSuggestions:
      case GalleryType.cleanupHiddenFromDevice:
        return false;
    }
  }

  bool showDeleteOption() {
    switch (this) {
      case GalleryType.ownedCollection:
      case GalleryType.sharedCollection:
      case GalleryType.searchResults:
      case GalleryType.homepage:
      case GalleryType.favorite:
      case GalleryType.uncategorized:
      case GalleryType.archive:
      case GalleryType.hiddenSection:
      case GalleryType.hiddenOwnedCollection:
      case GalleryType.localFolder:
      case GalleryType.locationTag:
      case GalleryType.quickLink:
      case GalleryType.peopleTag:
      case GalleryType.cluster:
      case GalleryType.magic:
        return true;
      case GalleryType.trash:
      case GalleryType.sharedPublicCollection:
      case GalleryType.deleteSuggestions:
      case GalleryType.cleanupHiddenFromDevice:
        return false;
    }
  }

  bool showAddToPersonOption() {
    switch (this) {
      case GalleryType.homepage:
      case GalleryType.archive:
      case GalleryType.uncategorized:
      case GalleryType.favorite:
      case GalleryType.ownedCollection:
      case GalleryType.searchResults:
      case GalleryType.locationTag:
      case GalleryType.peopleTag:
      case GalleryType.cluster:
      case GalleryType.magic:
        return true;

      case GalleryType.trash:
      case GalleryType.deleteSuggestions:
      case GalleryType.sharedCollection:
      case GalleryType.sharedPublicCollection:
      case GalleryType.quickLink:
      case GalleryType.localFolder:
      case GalleryType.hiddenSection:
      case GalleryType.hiddenOwnedCollection:
      case GalleryType.cleanupHiddenFromDevice:
        return false;
    }
  }

  bool showRestoreOption() {
    return this == GalleryType.trash;
  }

  bool showPermanentlyDeleteOption() {
    return this == GalleryType.trash;
  }

  bool showEditLocation() {
    return this != GalleryType.sharedCollection &&
        this != GalleryType.cluster &&
        this != GalleryType.cleanupHiddenFromDevice;
  }

  bool showBulkEditTime() {
    return this != GalleryType.sharedCollection &&
        this != GalleryType.cluster &&
        this != GalleryType.cleanupHiddenFromDevice;
  }
}

extension GalleryAppBarExtn on GalleryType {
  bool showMap() {
    switch (this) {
      case GalleryType.homepage:
      case GalleryType.archive:
      case GalleryType.hiddenSection:
      case GalleryType.trash:
      case GalleryType.locationTag:
      case GalleryType.searchResults:
      case GalleryType.magic:
      case GalleryType.sharedPublicCollection:
      case GalleryType.deleteSuggestions:
      case GalleryType.cleanupHiddenFromDevice:
        return false;
      case GalleryType.localFolder:
      case GalleryType.uncategorized:
      case GalleryType.cluster:
      case GalleryType.peopleTag:
      case GalleryType.ownedCollection:
      case GalleryType.sharedCollection:
      case GalleryType.quickLink:
      case GalleryType.favorite:
      case GalleryType.hiddenOwnedCollection:
        return true;
    }
  }
}
