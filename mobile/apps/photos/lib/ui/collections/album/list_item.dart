import "package:ente_components/ente_components.dart";
import "package:ente_components/hugeicons.dart";
import "package:ente_icons/ente_icons.dart";
import "package:ente_strings/ente_strings.dart";
import "package:flutter/material.dart";
import "package:logging/logging.dart";
import "package:photos/core/configuration.dart";
import "package:photos/models/collection/collection.dart";
import "package:photos/models/file/file.dart";
import "package:photos/models/selected_albums.dart";
import "package:photos/services/collections_service.dart";
import "package:photos/ui/components/collection_share_badge.dart";
import "package:photos/ui/components/thumbnail_list_item.dart";
import "package:photos/ui/viewer/file/no_thumbnail_widget.dart";
import "package:photos/ui/viewer/file/thumbnail_widget.dart";

class AlbumListItemWidget extends StatelessWidget {
  static const double _trailingHeight = 24.0;
  static const double _trailingWidth = _trailingHeight + 18.0;

  final Collection collection;
  final String? tag;
  final void Function(Collection)? onTapCallback;
  final void Function(Collection)? onLongPressCallback;
  final SelectedAlbums? selectedAlbums;
  final bool isSelected;
  final bool Function(EnteFile)? canShowCover;

  const AlbumListItemWidget(
    this.collection, {
    super.key,
    this.tag,
    this.onTapCallback,
    this.onLongPressCallback,
    this.selectedAlbums,
    this.isSelected = false,
    this.canShowCover,
  });

  @override
  Widget build(BuildContext context) {
    if (selectedAlbums == null) {
      return _buildItem(context, isSelected: isSelected);
    }
    return ListenableBuilder(
      listenable: selectedAlbums!,
      builder: (context, _) {
        return _buildItem(
          context,
          isSelected: selectedAlbums!.isAlbumSelected(collection),
        );
      },
    );
  }

  Widget _buildItem(BuildContext context, {required bool isSelected}) {
    final bool isOwner = collection.isOwner(
      Configuration.instance.getUserID() ?? -1,
    );
    final bool isOutgoing = isOwner && collection.hasSharees;
    final bool isIncoming = !isOwner;
    final bool showSharingIndicator = isOutgoing || isIncoming;
    final bool showLinkIndicator = isOwner && collection.hasLink;
    final bool isFavoriteAlbum = collection.type == CollectionType.favorites;
    final bool showPin = isOwner
        ? collection.isPinned
        : collection.hasShareePinned();
    final bool showArchive = isOwner
        ? collection.isArchived()
        : collection.hasShareeArchived();

    final colors = context.componentColors;
    return ThumbnailListItem(
      backgroundColor: thumbnailListItemBackgroundColor(context),
      selectedBorderColor: colors.strokeDark,
      isSelected: isSelected,
      onTap: onTapCallback == null ? null : () => onTapCallback!(collection),
      onLongPress: onLongPressCallback == null
          ? null
          : () => onLongPressCallback!(collection),
      leading: AlbumListItemCover(
        collection: collection,
        canShowCover: canShowCover,
        heroTag: tag == null
            ? null
            : (isOwner ? "collection" : "shared_collection") +
                  tag! +
                  "_" +
                  collection.id.toString(),
      ),
      title: _buildTitle(
        context,
        showSharingIndicator: showSharingIndicator,
        isOutgoing: isOutgoing,
        showLinkIndicator: showLinkIndicator,
      ),
      subtitle: FutureBuilder<int>(
        future: CollectionsService.instance.getFileCount(collection),
        initialData: CollectionsService.instance.getCachedFileCount(collection),
        builder: (context, snapshot) {
          String countText = "";
          if (snapshot.hasData) {
            countText = context.strings.itemCount(count: snapshot.data!);
          } else if (snapshot.hasError) {
            Logger("AlbumListItemWidget").severe(
              "Failed to fetch file count of collection",
              snapshot.error,
            );
          } else {
            final cachedCount = CollectionsService.instance.getCachedFileCount(
              collection,
            );
            if (cachedCount != null) {
              countText = context.strings.itemCount(count: cachedCount);
            }
          }
          return _buildSubtitle(
            context,
            text: countText,
            showPin: showPin,
            showArchive: showArchive,
            isFavoriteAlbum: isFavoriteAlbum,
          );
        },
      ),
      trailing: Padding(
        padding: const EdgeInsets.only(right: 8),
        child: SizedBox(
          width: _trailingWidth,
          height: _trailingHeight,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            layoutBuilder: (currentChild, previousChildren) {
              return Stack(
                alignment: Alignment.centerRight,
                children: [...previousChildren, ?currentChild],
              );
            },
            child: _buildTrailingIndicator(context, isSelected: isSelected),
          ),
        ),
      ),
    );
  }

  Widget _buildTitle(
    BuildContext context, {
    required bool showSharingIndicator,
    required bool isOutgoing,
    required bool showLinkIndicator,
  }) {
    final colors = context.componentColors;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Flexible(
          child: Text(
            collection.displayName,
            style: TextStyles.body.copyWith(color: colors.textBase),
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (showSharingIndicator) ...[
          const SizedBox(width: 6),
          CollectionShareBadge(
            isOutgoing: isOutgoing,
            variant: CollectionShareBadgeVariant.outlined,
          ),
        ],
        if (showLinkIndicator) ...[
          const SizedBox(width: 4),
          const CollectionLinkBadge(
            variant: CollectionShareBadgeVariant.outlined,
          ),
        ],
      ],
    );
  }

  Widget _buildSubtitle(
    BuildContext context, {
    required String text,
    required bool showPin,
    required bool showArchive,
    required bool isFavoriteAlbum,
  }) {
    final colors = context.componentColors;
    final textStyle = TextStyles.mini.copyWith(color: colors.textLight);
    final hasStatus = showPin || showArchive || isFavoriteAlbum;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Flexible(
          child: Text(
            text,
            style: textStyle,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (hasStatus) ...[
          Text(" \u2022 ", style: textStyle),
          if (showPin)
            ImageIcon(
              const AssetImage("assets/collection_pin.png"),
              size: 12,
              color: colors.textBase,
            ),
          if (showArchive)
            HugeIcon(
              icon: HugeIcons.strokeRoundedArchive03,
              size: 12,
              color: colors.textBase,
              strokeWidth: 2.0,
            ),
          if (isFavoriteAlbum)
            Icon(EnteIcons.favoriteFilled, size: 12, color: colors.textBase),
        ],
      ],
    );
  }

  Widget _buildTrailingIndicator(
    BuildContext context, {
    required bool isSelected,
  }) {
    if (isSelected) {
      return const CollectionSelectedBadge(key: ValueKey("selected"));
    }
    return const SizedBox.shrink(key: ValueKey("unselected"));
  }
}

class AlbumListItemCover extends StatelessWidget {
  const AlbumListItemCover({
    required this.collection,
    this.heroTag,
    this.canShowCover,
    this.borderRadius = ThumbnailListItem.defaultLeadingRadius,
    super.key,
  });

  final Collection collection;
  final String? heroTag;
  final double borderRadius;
  final bool Function(EnteFile)? canShowCover;

  @override
  Widget build(BuildContext context) {
    final cover = ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: SizedBox.expand(
        child: FutureBuilder<EnteFile?>(
          future: CollectionsService.instance.getCover(collection),
          initialData: CollectionsService.instance.getCoverCache(collection),
          builder: (context, snapshot) {
            final thumbnail =
                snapshot.data ??
                CollectionsService.instance.getCoverCache(collection);
            if (thumbnail == null || canShowCover?.call(thumbnail) == false) {
              return NoThumbnailWidget(
                borderRadius: borderRadius,
                addBorder: false,
              );
            }
            return ThumbnailWidget(
              thumbnail,
              shouldShowFavoriteIcon: false,
              shouldShowSyncStatus: false,
              key: Key("album_list:${collection.id}:${thumbnail.tag}"),
            );
          },
        ),
      ),
    );
    if (heroTag == null) return cover;
    return Hero(
      tag: heroTag!,
      createRectTween: (begin, end) => RectTween(begin: begin, end: end),
      transitionOnUserGestures: true,
      child: cover,
    );
  }
}
