/*
 * Swiftify, a spotify player for desktop
 * Copyright (C) 2026  shred0s
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls.Basic
import QtQuick.Templates as T
import Swiftify

// Now Playing (NowPlayingPanel): full-width artwork with blurred metadata
// overlay, action buttons, the lyrics column below it, and a next-song button.
Item {
    id: root

    /// under the immersive player: the lines change, nothing scrolls
    property bool suspended: false
    property MaterialScheme scheme: Appearance.colors
    readonly property bool lyricsMaximized: Settings.nowPlayingLyricsExpanded
    property real maxProgress: lyricsMaximized ? 1 : 0
    readonly property real fadeProgress: Math.max(0, Math.min(1, maxProgress))
    readonly property bool hasNextSong: Player.hasSong && Player.upNext.count > 0
    readonly property song nextSong: Player.upNext.at(Player.upNext.count > 0 ? 0 : -1)
    readonly property bool hasPreviousSong: Player.hasSong && Player.previouslyPlayed.count > 0
    readonly property song previousSong: Player.previouslyPlayed.at(Player.previouslyPlayed.count - 1)
    readonly property real bottomButtonsHeight: (hasNextSong ? nextButton.height + 10 : 0)
                                              + (hasPreviousSong ? prevButton.height + (hasNextSong ? 8 : 10) : 0)
                                              + 18
    readonly property real fullCoverSize: Math.max(0, Math.round(root.width - 36))
    readonly property real availableCoverHeight: root.height - 36 - 20 - lyricsContainer.minLyricsHeight - bottomButtonsHeight
    readonly property bool compactCover: Player.hasSong && fullCoverSize > 0 && availableCoverHeight < fullCoverSize * 0.5
    property real compactProgress: compactCover ? 1 : 0
    readonly property real compactBlend: Math.max(0, Math.min(1, compactProgress))
    readonly property real normalCoverHeight: Math.round(Math.min(fullCoverSize, Math.max(fullCoverSize * 0.5, availableCoverHeight)))
    readonly property real coverHeight: !Player.hasSong ? 0
                                        : Math.round(normalCoverHeight + (96 - normalCoverHeight) * compactBlend)
    readonly property bool coverHovered: coverHover.hovered && !textHover.hovered && !moreButton.hovered

    property bool hadSong: false
    property int slideDir: 1
    property song shownSong
    property song outgoingSong
    property song shownNextSong
    property song outgoingNextSong
    property song shownPrevSong
    property song outgoingPrevSong
    property real coverProgress: 1
    property real nextProgress: 1
    property real prevProgress: 1
    clip: true

    function escapeHtml(value: string): string {
        return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    }

    function snapDisplayedSongs(): void {
        coverSlideAnim.stop()
        nextSlideAnim.stop()
        prevSlideAnim.stop()
        shownSong = Player.currentSong
        shownNextSong = nextSong
        shownPrevSong = previousSong
        outgoingSong = Player.currentSong
        outgoingNextSong = nextSong
        outgoingPrevSong = previousSong
        coverProgress = 1
        nextProgress = 1
        prevProgress = 1
    }

    Component.onCompleted: {
        hadSong = Player.hasSong
        snapDisplayedSongs()
    }

    onNextSongChanged: {
        if (!Player.hasSong || shownSong.instanceId !== Player.currentSong.instanceId) {
            return
        }
        if (nextSlideAnim.running) {
            shownNextSong = nextSong
        } else {
            shownNextSong = nextSong
            outgoingNextSong = nextSong
        }
    }

    onPreviousSongChanged: {
        if (!Player.hasSong || shownSong.instanceId !== Player.currentSong.instanceId) {
            return
        }
        if (prevSlideAnim.running) {
            shownPrevSong = previousSong
        } else {
            shownPrevSong = previousSong
            outgoingPrevSong = previousSong
        }
    }

    Connections {
        target: Player
        function onCurrentSongChanged(): void {
            const nowHasSong = Player.hasSong
            const incoming = Player.currentSong
            if (!nowHasSong || !root.hadSong || root.shownSong.instanceId === ""
                    || incoming.instanceId === root.shownSong.instanceId
                    || Appearance.performanceMode || Appearance.reduceMotion) {
                root.hadSong = nowHasSong
                root.snapDisplayedSongs()
                return
            }

            const prev = root.shownPrevSong
            const isPrev = prev.instanceId !== ""
                           && (incoming.instanceId === prev.instanceId
                               || (prev.uri !== "" && incoming.uri === prev.uri && incoming.uri !== root.shownSong.uri))
            root.slideDir = isPrev ? -1 : 1
            root.outgoingSong = root.shownSong
            root.shownSong = incoming
            root.outgoingNextSong = root.shownNextSong
            root.shownNextSong = root.nextSong
            root.outgoingPrevSong = root.shownPrevSong
            root.shownPrevSong = root.previousSong
            root.hadSong = true

            root.coverProgress = 0
            coverSlideAnim.restart()

            if (root.outgoingNextSong.instanceId !== root.shownNextSong.instanceId) {
                root.nextProgress = 0
                nextSlideAnim.restart()
            } else {
                nextSlideAnim.stop()
                root.nextProgress = 1
            }

            if (root.outgoingPrevSong.instanceId !== root.shownPrevSong.instanceId) {
                root.prevProgress = 0
                prevSlideAnim.restart()
            } else {
                prevSlideAnim.stop()
                root.prevProgress = 1
            }
        }
    }

    NumberAnimation {
        id: coverSlideAnim
        target: root
        property: "coverProgress"
        from: 0
        to: 1
        duration: Appearance.motion(450)
        easing.type: Easing.BezierSpline
        easing.bezierCurve: Appearance.curves.expressiveDefaultSpatial
    }

    SequentialAnimation {
        id: nextSlideAnim
        PauseAnimation { duration: Appearance.duration(50) }
        NumberAnimation {
            target: root
            property: "nextProgress"
            from: 0
            to: 1
            duration: Appearance.motion(450)
            easing.type: Easing.BezierSpline
            easing.bezierCurve: Appearance.curves.expressiveDefaultSpatial
        }
    }

    SequentialAnimation {
        id: prevSlideAnim
        PauseAnimation { duration: Appearance.duration(100) }
        NumberAnimation {
            target: root
            property: "prevProgress"
            from: 0
            to: 1
            duration: Appearance.motion(450)
            easing.type: Easing.BezierSpline
            easing.bezierCurve: Appearance.curves.expressiveDefaultSpatial
        }
    }

    component CoverSlide: Item {
        required property song songData

        ArtworkImage {
            anchors.fill: parent
            radius: Appearance.sizes.artworkRadius
            source: parent.songData.artworkUrl
            crossfade: false
        }

        Rectangle {
            anchors.fill: parent
            radius: Appearance.sizes.artworkRadius
            opacity: 1 - root.compactBlend
            visible: opacity > 0.005
            gradient: Gradient {
                GradientStop {
                    position: Math.max(0.1, 1.0 - overlayBox.blurReach / Math.max(1, artwork.height))
                    color: "transparent"
                }
                GradientStop {
                    position: Math.max(0.2, 1.0 - (overlayBox.blurReach * 0.5) / Math.max(1, artwork.height))
                    color: Qt.rgba(0, 0, 0, 0.28)
                }
                GradientStop {
                    position: 1.0
                    color: Qt.rgba(0, 0, 0, Appearance.performanceMode ? 0.68 : 0.52)
                }
            }
        }

        Rectangle {
            anchors.fill: parent
            radius: Appearance.sizes.artworkRadius
            opacity: root.compactBlend
            visible: opacity > 0.005
            color: Qt.rgba(0, 0, 0, root.coverHovered ? 0.28 : (Appearance.performanceMode ? 0.62 : 0.46))

            Behavior on color {
                ElementMoveFastColor {}
            }
        }

        Rectangle {
            anchors.fill: parent
            radius: Appearance.sizes.artworkRadius
            opacity: 1 - root.compactBlend
            visible: opacity > 0.005
            color: Qt.rgba(0, 0, 0, root.coverHovered && Player.hasSong ? 0.25 : 0)

            Behavior on color {
                ColorAnimation { duration: Appearance.duration(160) }
            }
        }
    }

    component MetadataSlide: Column {
        required property song songData
        readonly property real maxLineWidth: Math.max(titleText.implicitWidth, artistText.implicitWidth)
        spacing: 2

        StyledText {
            id: titleText
            width: parent.width
            text: parent.songData.name
            elide: Text.ElideRight
            font.pixelSize: Appearance.fontSize.normal
            font.weight: Font.Bold
            color: "white"
        }
        StyledText {
            id: artistText
            width: parent.width
            text: parent.songData.artists
            elide: Text.ElideRight
            font.pixelSize: Appearance.fontSize.smallie
            color: Qt.rgba(1, 1, 1, 0.82)
        }
    }

    component NextInfoSlide: Item {
        id: nextSlideRoot
        required property song songData

        ArtworkImage {
            id: nextArt
            x: 8
            anchors.verticalCenter: parent.verticalCenter
            width: 38
            height: 38
            radius: Appearance.sizes.smallArtworkRadius
            source: nextSlideRoot.songData.artworkUrl
            crossfade: false
        }

        Column {
            anchors.left: nextArt.right
            anchors.leftMargin: 10
            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1

            StyledText {
                width: parent.width
                text: nextSlideRoot.songData.name
                elide: Text.ElideRight
                font.pixelSize: Appearance.fontSize.smallie
                font.weight: Font.DemiBold
                color: root.scheme.onSurface
            }
            StyledText {
                width: parent.width
                text: nextSlideRoot.songData.artists
                elide: Text.ElideRight
                font.pixelSize: Appearance.fontSize.smaller
                color: root.scheme.onSurfaceVariant
            }
        }
    }

    component PrevInfoSlide: StyledText {
        required property song songData
        textFormat: Text.StyledText
        maximumLineCount: 1
        text: songData.artists.length > 0
              ? "<b>" + root.escapeHtml(songData.name) + "</b> - " + root.escapeHtml(songData.artists)
              : "<b>" + root.escapeHtml(songData.name) + "</b>"
        elide: Text.ElideRight
        font.pixelSize: Appearance.fontSize.smaller
        color: prevButton.hovered ? root.scheme.onSurface : root.scheme.onSurfaceVariant

        Behavior on color {
            ElementMoveFastColor {}
        }
    }

    Behavior on maxProgress {
        enabled: !Appearance.performanceMode
        ElementMove {}
    }

    Behavior on compactProgress {
        enabled: !Appearance.performanceMode
        ElementMoveFast {}
    }

    T.AbstractButton {
        id: header

        x: 18
        y: Math.round((36 - implicitHeight) / 2)
        z: 1
        width: Math.min(implicitWidth, Math.max(0, root.width - (Settings.windowControlsOnRight ? 132 : 36)))
        padding: 0
        hoverEnabled: true
        enabled: Library.hasPlaybackSource
        focusPolicy: Qt.TabFocus

        onClicked: Library.openPlaybackSource()

        contentItem: StyledText {
            text: Library.playbackSourceLabel
            elide: Text.ElideRight
            font.pixelSize: Appearance.fontSize.smallie
            font.weight: Font.DemiBold
            color: header.enabled && header.hovered ? root.scheme.onSurface : root.scheme.onSurfaceVariant

            Behavior on color {
                ElementMoveFastColor {}
            }
        }

        HoverHandler {
            cursorShape: header.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        }
    }

    Item {
        id: artworkStage
        readonly property real topBleed: 10 * root.compactBlend
        anchors.top: parent.top
        anchors.topMargin: 36 - topBleed
        anchors.left: parent.left
        anchors.right: parent.right
        height: topBleed + root.coverHeight + overlayBox.bleed
        opacity: 1 - root.fadeProgress
        visible: Player.hasSong && opacity > 0.005
        enabled: !root.lyricsMaximized

        Item {
            id: artworkContainer
            anchors.fill: parent

            Rectangle {
                anchors.fill: parent
                color: root.scheme.layer1
            }

            Item {
                id: artwork
                x: 18
                y: artworkStage.topBleed
                width: root.fullCoverSize
                height: root.coverHeight
                clip: true
                scale: root.coverHovered ? 1.035 : 1

                Behavior on scale {
                    enabled: !Appearance.performanceMode
                    NumberAnimation {
                        duration: Appearance.motion(220)
                        easing.type: Easing.OutBack
                    }
                }

                CoverSlide {
                    width: parent.width
                    height: parent.height
                    songData: root.outgoingSong
                    visible: root.coverProgress < 0.999 && root.outgoingSong.instanceId !== ""
                    x: -root.slideDir * parent.width * root.coverProgress
                    opacity: Math.max(0, 1 - root.coverProgress * 1.4)
                }

                CoverSlide {
                    width: parent.width
                    height: parent.height
                    songData: root.shownSong
                    x: root.slideDir * parent.width * (1 - root.coverProgress)
                    opacity: Math.min(1, root.coverProgress * 2.2)
                }
            }
        }

        Item {
            id: overlayBox
            readonly property real bleed: 24 - 8 * root.compactBlend
            readonly property real blurReach: Math.round(Math.min(root.coverHeight, Math.max(metadataColumn.implicitHeight, overlayButtons.implicitHeight) + 72))
            readonly property real normalHeight: Math.round(Math.min(artworkStage.height, blurReach + bleed))
            property real targetSigma: Appearance.performanceMode ? 0 : (root.coverHovered ? 1.2 : 9.5)
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: Math.round(normalHeight + (artworkStage.height - normalHeight) * root.compactBlend)
            visible: artwork.width > 0

            Behavior on targetSigma {
                enabled: !Appearance.performanceMode
                NumberAnimation { duration: Appearance.duration(220); easing.type: Easing.OutCubic }
            }

            ShaderEffectSource {
                id: stageCapture
                anchors.fill: parent
                sourceItem: artworkContainer
                sourceRect: Qt.rect(0, Math.round(overlayBox.y), Math.round(artworkContainer.width), Math.round(overlayBox.height))
                live: root.visible && Player.hasSong && overlayBox.width > 0
                hideSource: false
                visible: false
                smooth: true
            }

            ShaderEffect {
                id: across
                anchors.fill: parent
                property variant source: stageCapture
                property size itemSize: Qt.size(width, height)
                property vector2d direction: Qt.vector2d(1, 0)
                property real maxSigma: overlayBox.targetSigma
                property real blurEndY: (overlayBox.height - overlayBox.bleed) / Math.max(1, overlayBox.height)
                property real uniformBlur: root.compactBlend
                fragmentShader: "qrc:/shaders/progressive_blur.frag.qsb"
            }

            ShaderEffectSource {
                id: acrossTexture
                anchors.fill: parent
                sourceItem: across
                hideSource: true
                visible: false
                smooth: true
            }

            ShaderEffect {
                anchors.fill: parent
                property variant source: acrossTexture
                property size itemSize: Qt.size(width, height)
                property vector2d direction: Qt.vector2d(0, 1)
                property real maxSigma: overlayBox.targetSigma
                property real blurEndY: (overlayBox.height - overlayBox.bleed) / Math.max(1, overlayBox.height)
                property real uniformBlur: root.compactBlend
                fragmentShader: "qrc:/shaders/progressive_blur.frag.qsb"
            }

            MouseArea {
                x: artwork.x
                y: artwork.y - overlayBox.y
                width: artwork.width
                height: artwork.height
                onClicked: {
                    if (Player.hasSong && !textHover.hovered) {
                        UiState.immersiveOpen = true
                    }
                }

                HoverHandler {
                    id: coverHover
                    cursorShape: root.coverHovered && Player.hasSong ? Qt.PointingHandCursor : Qt.ArrowCursor
                }
            }

            Item {
                id: metadataColumn
                readonly property real normalY: overlayBox.height - overlayBox.bleed - 12 - height
                readonly property real compactY: artwork.y - overlayBox.y + (artwork.height - height) / 2
                anchors.left: parent.left
                anchors.leftMargin: 32
                anchors.right: overlayButtons.left
                anchors.rightMargin: 8
                y: Math.round(normalY + (compactY - normalY) * root.compactBlend)
                height: incomingMetadata.implicitHeight
                implicitHeight: incomingMetadata.implicitHeight
                clip: true

                MetadataSlide {
                    width: parent.width
                    songData: root.outgoingSong
                    visible: root.coverProgress < 0.999 && root.outgoingSong.instanceId !== ""
                    x: -root.slideDir * parent.width * root.coverProgress
                    opacity: Math.max(0, 1 - root.coverProgress * 1.4)
                }

                MetadataSlide {
                    id: incomingMetadata
                    width: parent.width
                    songData: root.shownSong
                    x: root.slideDir * parent.width * (1 - root.coverProgress)
                    opacity: Math.min(1, root.coverProgress * 2.2)
                }
            }

            Item {
                x: metadataColumn.x
                y: metadataColumn.y
                width: Math.min(metadataColumn.width, incomingMetadata.maxLineWidth)
                height: metadataColumn.height

                HoverHandler {
                    id: textHover
                }
            }

            Row {
                id: overlayButtons
                anchors.right: parent.right
                anchors.rightMargin: 26
                anchors.verticalCenter: metadataColumn.verticalCenter

                IconButton {
                    id: moreButton
                    scheme: root.scheme
                    symbol: "more_horiz"
                    size: 32
                    iconSize: 18
                    iconColor: "white"
                    colBackgroundHover: Qt.rgba(1, 1, 1, 0.14)
                    enabled: Player.hasSong
                    tooltip: qsTr("More options")
                    onClicked: SongMenus.open(Player.currentSong, false)
                }
            }
        }

        MaterialSymbol {
            readonly property real normalX: artwork.x + (artwork.width - width) / 2
            readonly property real compactX: artwork.x + artwork.width - width - 10
            readonly property real normalY: artwork.y + (artwork.height - height) / 2
            readonly property real compactY: artwork.y + 8
            x: Math.round(normalX + (compactX - normalX) * root.compactBlend)
            y: Math.round(normalY + (compactY - normalY) * root.compactBlend)
            text: "open_in_full"
            iconSize: Math.round(28 - 10 * root.compactBlend)
            weight: 600
            color: "white"
            opacity: root.coverHovered && Player.hasSong ? 1 : 0

            Behavior on opacity {
                NumberAnimation { duration: Appearance.duration(160) }
            }
        }
    }

    Rectangle {
        id: lyricsContainer
        readonly property real minLyricsHeight: 280
        readonly property real normalY: Player.hasSong ? 36 + artwork.height + 20 : 38
        readonly property real normalHeight: Math.max(minLyricsHeight, root.height - normalY - root.bottomButtonsHeight)
        x: Math.round(18 * (1 - root.maxProgress))
        y: Math.round(normalY + (36 - normalY) * root.maxProgress)
        width: Math.max(0, Math.round(root.width - 36 * (1 - root.maxProgress)))
        height: Math.max(0, Math.round(normalHeight + (root.height - 36 - normalHeight) * root.maxProgress))
        radius: Appearance.rounding.normal * (1 - root.fadeProgress)
        color: root.lyricsMaximized ? root.scheme.layer1 : root.scheme.layer2
        clip: true

        Behavior on color {
            ColorAnimation {
                duration: Appearance.duration(300)
                easing.type: Easing.OutCubic
            }
        }

        Item {
            id: lyricsHeader
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.topMargin: Math.round(10 - 6 * root.fadeProgress)
            anchors.leftMargin: Math.round(16 + 2 * root.fadeProgress)
            anchors.rightMargin: Math.round(10 + 4 * root.fadeProgress)
            height: maximizeLyricsButton.height

            StyledText {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: qsTr("Lyrics")
                font.pixelSize: Appearance.fontSize.smallie
                font.weight: Font.DemiBold
                color: root.scheme.onSurfaceVariant
            }

            IconButton {
                id: maximizeLyricsButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                scheme: root.scheme
                symbol: root.lyricsMaximized ? "close_fullscreen" : "open_in_full"
                size: 30
                iconSize: 16
                tooltip: root.lyricsMaximized ? qsTr("Restore lyrics") : qsTr("Expand lyrics")
                contentItem: Item {
                    MaterialSymbol {
                        anchors.centerIn: parent
                        text: maximizeLyricsButton.symbol
                        iconSize: maximizeLyricsButton.iconSize
                        color: maximizeLyricsButton.iconColor
                        rotation: -45

                        Behavior on color {
                            ElementMoveFastColor {}
                        }
                    }
                }
                onClicked: {
                    Settings.nowPlayingLyricsExpanded = !Settings.nowPlayingLyricsExpanded
                    Qt.callLater(() => list.follow(true))
                }
            }
        }

        Item {
            id: lyricsArea
            anchors.top: lyricsHeader.bottom
            anchors.topMargin: 2
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            clip: true

            Column {
                anchors.centerIn: parent
                Reveal.shown: Player.loadingLyrics
                spacing: 12
                LoadingSpinner { anchors.horizontalCenter: parent.horizontalCenter }
                StyledText {
                    text: qsTr("Loading lyrics…")
                    color: root.scheme.onSurfaceVariant
                }
            }

            EmptyState {
                anchors.centerIn: parent
                width: parent.width - 32
                Reveal.shown: !Player.loadingLyrics && !Player.hasLyrics
                symbol: "lyrics"
                title: qsTr("Lyrics Unavailable")
                description: Player.lyricsMessage.length > 0 ? qsTranslate("Errors", Player.lyricsMessage) : qsTr("i guess bro")
            }

            ListView {
                id: list
                anchors.fill: parent
                Reveal.shown: !Player.loadingLyrics && Player.hasLyrics
                model: Player.lyrics
                spacing: 14
                topMargin: 18
                bottomMargin: Math.round(22 + 2 * root.fadeProgress)
                leftMargin: Math.round(16 + 8 * root.fadeProgress)
                rightMargin: Math.round(16 + 8 * root.fadeProgress)
                clip: true
                boundsBehavior: Flickable.DragAndOvershootBounds
                cacheBuffer: 2000
                signal stepped(real delta)

                layer.enabled: width > 0 && height > 0
                layer.effect: ShaderEffect {
                    property variant source
                    property size itemSize: Qt.size(list.width, list.height)
                    property real edgePx: 32
                    property real maxSigma: Appearance.performanceMode ? 0 : 1.2
                    fragmentShader: "qrc:/shaders/lyrics_edge_fade.frag.qsb"
                }

                ScrollBar.vertical: StyledScrollBar {}

                function follow(animated: bool) {
                    const index = Player.activeLyricIndex
                    if (index < 0 || root.suspended) {
                        return
                    }
                    const item = list.itemAtIndex(index)
                    if (!item) {
                        scroll.stop()
                        list.positionViewAtIndex(index, ListView.Center)
                        return
                    }
                    const target = Math.max(list.originY - list.topMargin,
                                            Math.min(item.y + item.height / 2 - list.height / 2,
                                                     list.contentHeight + list.originY - list.height + list.bottomMargin))
                    const delta = target - list.contentY
                    scroll.stop()
                    if (animated && Appearance.reduceMotion && !Appearance.performanceMode) {
                        scroll.to = target
                        scroll.start()
                        return
                    }
                    list.contentY = target
                    if (animated && !Appearance.reduceMotion) {
                        list.stepped(delta)
                    }
                }

                NumberAnimation {
                    id: scroll
                    target: list
                    property: "contentY"
                    duration: 420
                    easing.type: Easing.OutCubic
                }

                Connections {
                    target: Player
                    function onActiveLyricIndexChanged() { list.follow(true) }
                }
                Connections {
                    target: root
                    function onSuspendedChanged() { if (!root.suspended) list.follow(false) }
                }

                delegate: Item {
                    id: line

                    required property int index
                    required property string words
                    required property int startTimeMs
                    readonly property bool active: !Player.lyricsSynchronized || Player.activeLyricIndex === index
                    readonly property bool highlighted: Player.lyricsSynchronized && Player.activeLyricIndex === index

                    width: list.width - list.leftMargin - list.rightMargin
                    height: text.implicitHeight + (highlighted ? 12 : 0)

                    property real lag: 0
                    transform: Translate { y: line.lag }

                    Connections {
                        target: list
                        function onStepped(delta: real) {
                            line.lag += delta
                            settle.restart()
                        }
                    }
                    SequentialAnimation {
                        id: settle
                        PauseAnimation { duration: Math.min(Math.abs(line.index - Player.activeLyricIndex), 8) * 16 }
                        NumberAnimation { target: line; property: "lag"; to: 0; duration: 560; easing.type: Easing.OutBack; easing.overshoot: 0.6 }
                    }

                    StyledText {
                        id: text
                        y: line.highlighted ? 6 : 0
                        width: parent.width
                        transformOrigin: Item.TopLeft
                        text: line.words.length > 0 ? line.words : "♪"
                        wrapMode: Text.Wrap
                        font.pixelSize: 20
                        font.weight: Font.Bold
                        color: root.scheme.onSurface
                        property real springing: line.active ? 1 : 17 / 20
                        property real eased: line.active ? 1 : 17 / 20
                        scale: Appearance.reduceMotion ? eased : springing
                        opacity: line.active ? 1 : 0.34

                        Behavior on springing {
                            enabled: !root.suspended && !Appearance.reduceMotion
                            Bounce {}
                        }
                        Behavior on eased {
                            enabled: !root.suspended && Appearance.reduceMotion && !Appearance.performanceMode
                            NumberAnimation { duration: 420; easing.type: Easing.OutCubic }
                        }
                        Behavior on opacity {
                            enabled: !root.suspended
                            NumberAnimation { duration: Appearance.duration(280); easing.type: Easing.InOutQuad }
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        enabled: Player.lyricsSynchronized
                        cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: Player.seekToLyricLine(line.index)
                    }
                }

                footer: StyledText {
                    topPadding: 18
                    text: qsTr("Lyrics provided by ") + Player.lyricsProvider
                    font.pixelSize: Appearance.fontSize.smaller
                    color: root.scheme.outline
                }
            }
        }
    }

    T.AbstractButton {
        id: nextButton

        readonly property list<string> badgeShapes: [
            "cookie4", "cookie6", "cookie7", "cookie9", "cookie12",
            "clover4", "clover8", "sunny", "verySunny", "softBurst",
            "flower", "puffy", "softCookie", "bun", "gem", "pentagon"
        ]
        property string badgeShape: "cookie9"

        anchors.top: lyricsContainer.bottom
        anchors.topMargin: 10
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 18
        anchors.rightMargin: 18
        height: 54
        opacity: 1 - root.fadeProgress
        visible: root.hasNextSong && opacity > 0.005
        enabled: Player.canSkipForward && !root.lyricsMaximized
        padding: 0
        hoverEnabled: true
        focusPolicy: Qt.TabFocus
        scale: down ? 0.96 : (hovered ? 1.01 : 1)

        Behavior on scale {
            enabled: !Appearance.performanceMode
            Bounce {}
        }

        onHoveredChanged: {
            if (hovered) {
                let pick = badgeShape
                while (pick === badgeShape && badgeShapes.length > 1) {
                    pick = badgeShapes[Math.floor(Math.random() * badgeShapes.length)]
                }
                badgeShape = pick
            }
        }

        onPressed: {
            if (Appearance.performanceMode || Settings.noShapes) {
                return
            }
            pressBurst.shape = badgeShape
            pressBurst.spinAngle = badgeDrift.value
            pressBurst.burstSize = 36
            pressBurst.morph = 0
            pressBurst.opacity = 0.9
            burstExpand.to = Math.max(nextButton.width * 2.1, nextButton.height * 2.1)
            burstAnim.restart()
        }

        onClicked: Player.skipForward()

        ParallelAnimation {
            id: burstAnim

            NumberAnimation {
                id: burstExpand
                target: pressBurst
                property: "burstSize"
                duration: Appearance.duration(440)
                easing.type: Easing.OutCubic
            }
            NumberAnimation {
                target: pressBurst
                property: "morph"
                from: 0
                to: 1
                duration: Appearance.duration(440)
                easing.type: Easing.OutCubic
            }
            NumberAnimation {
                target: pressBurst
                property: "opacity"
                from: 0.9
                to: 0
                duration: Appearance.duration(440)
                easing.type: Easing.OutCubic
            }
        }

        background: WavyClip {
            radius: Appearance.rounding.normal
            wavy: nextButton.hovered
            depth: 2.5
            wavelength: 18

            Rectangle {
                anchors.fill: parent
                radius: Appearance.rounding.normal
                color: nextButton.hovered ? root.scheme.surfaceContainerHighest : root.scheme.layer2

                Behavior on color {
                    ElementMoveFastColor {}
                }
            }

            MaterialShape {
                id: pressBurst
                property real burstSize: 36
                x: nextButton.width - 9 - 18 - width / 2
                y: nextButton.height / 2 - height / 2
                width: burstSize
                height: burstSize
                parentClipRadius: Appearance.rounding.normal
                shape: nextButton.badgeShape
                morphTo: "circle"
                color: root.scheme.layer4Active
                opacity: 0
                visible: opacity > 0.005
            }
        }

        contentItem: Item {
            anchors.fill: parent

            Item {
                anchors.left: parent.left
                anchors.right: nextBadge.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                clip: true

                NextInfoSlide {
                    width: parent.width
                    height: parent.height
                    songData: root.outgoingNextSong
                    visible: root.nextProgress < 0.999 && root.outgoingNextSong.instanceId !== ""
                    x: -root.slideDir * parent.width * root.nextProgress
                    opacity: Math.max(0, 1 - root.nextProgress * 1.4)
                }

                NextInfoSlide {
                    width: parent.width
                    height: parent.height
                    songData: root.shownNextSong
                    x: root.slideDir * parent.width * (1 - root.nextProgress)
                    opacity: Math.min(1, root.nextProgress * 2.2)
                }
            }

            Item {
                id: nextBadge
                anchors.right: parent.right
                anchors.rightMargin: 9
                anchors.verticalCenter: parent.verticalCenter
                width: 36
                height: 36

                MaterialShape {
                    id: nextBadgeShape
                    anchors.fill: parent
                    shape: nextButton.badgeShape
                    spinAngle: badgeDrift.value
                    color: root.scheme.layer4Active
                    scale: nextButton.hovered && !burstAnim.running ? 1 : 0
                    opacity: nextButton.hovered && !burstAnim.running ? 1 : 0

                    Behavior on scale {
                        enabled: !Appearance.performanceMode
                        Bounce {}
                    }
                    Behavior on opacity {
                        NumberAnimation { duration: Appearance.duration(140); easing.type: Easing.OutCubic }
                    }

                    Drift {
                        id: badgeDrift
                        active: nextButton.hovered && nextButton.visible && !Settings.noShapes
                        speed: -40
                        period: 360
                    }
                }

                MaterialSymbol {
                    anchors.centerIn: parent
                    text: "skip_next"
                    iconSize: 20
                    color: nextButton.hovered && !burstAnim.running ? root.scheme.onSurface : root.scheme.onSurfaceVariant

                    Behavior on color {
                        ElementMoveFastColor {}
                    }
                }
            }
        }

        HoverHandler {
            cursorShape: nextButton.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        }
    }

    T.AbstractButton {
        id: prevButton

        anchors.top: nextButton.visible ? nextButton.bottom : lyricsContainer.bottom
        anchors.topMargin: nextButton.visible ? 8 : 10
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 18
        anchors.rightMargin: 18
        height: 30
        opacity: 1 - root.fadeProgress
        visible: root.hasPreviousSong && opacity > 0.005
        enabled: Player.canSkipBackward && !root.lyricsMaximized
        padding: 0
        hoverEnabled: true
        focusPolicy: Qt.TabFocus
        scale: down ? 0.97 : (hovered ? 1.01 : 1)

        Behavior on scale {
            enabled: !Appearance.performanceMode
            Bounce {}
        }

        onClicked: Player.skipToPreviousSong()

        background: Rectangle {
            radius: Appearance.rounding.small
            color: prevButton.down ? root.scheme.layer2Active : (prevButton.hovered ? root.scheme.surfaceContainerHighest : root.scheme.layer2)

            Behavior on color {
                ElementMoveFastColor {}
            }
        }

        contentItem: Item {
            anchors.fill: parent

            MaterialSymbol {
                id: prevIcon
                anchors.left: parent.left
                anchors.leftMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                text: "skip_previous"
                iconSize: 16
                color: prevButton.hovered ? root.scheme.onSurface : root.scheme.onSurfaceVariant

                Behavior on color {
                    ElementMoveFastColor {}
                }
            }

            Item {
                anchors.left: prevIcon.right
                anchors.leftMargin: 6
                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                clip: true

                PrevInfoSlide {
                    width: parent.width
                    anchors.verticalCenter: parent.verticalCenter
                    songData: root.outgoingPrevSong
                    visible: root.prevProgress < 0.999 && root.outgoingPrevSong.instanceId !== ""
                    x: -root.slideDir * parent.width * root.prevProgress
                    opacity: Math.max(0, 1 - root.prevProgress * 1.4)
                }

                PrevInfoSlide {
                    width: parent.width
                    anchors.verticalCenter: parent.verticalCenter
                    songData: root.shownPrevSong
                    x: root.slideDir * parent.width * (1 - root.prevProgress)
                    opacity: Math.min(1, root.prevProgress * 2.2)
                }
            }
        }

        HoverHandler {
            cursorShape: prevButton.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        }
    }
}
