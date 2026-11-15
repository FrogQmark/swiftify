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
    readonly property real coverHeight: !Player.hasSong ? 0
                                        : (compactCover ? 96 : Math.round(Math.min(fullCoverSize, Math.max(fullCoverSize * 0.5, availableCoverHeight))))
    readonly property bool coverHovered: coverHover.hovered && !textHover.hovered && !moreButton.hovered
    clip: true

    function escapeHtml(value: string): string {
        return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    }

    Behavior on maxProgress {
        enabled: !Appearance.performanceMode
        ElementMove {}
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
        readonly property real topBleed: root.compactCover ? 10 : 0
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
                scale: root.coverHovered ? 1.035 : 1

                Behavior on scale {
                    enabled: !Appearance.performanceMode
                    NumberAnimation {
                        duration: Appearance.motion(220)
                        easing.type: Easing.OutBack
                    }
                }

                ArtworkImage {
                    anchors.fill: parent
                    radius: Appearance.sizes.artworkRadius
                    source: Player.currentSong.artworkUrl
                    crossfade: true
                }

                Rectangle {
                    anchors.fill: parent
                    radius: Appearance.sizes.artworkRadius
                    visible: !root.compactCover
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
                    visible: root.compactCover
                    color: Qt.rgba(0, 0, 0, root.coverHovered ? 0.28 : (Appearance.performanceMode ? 0.62 : 0.46))

                    Behavior on color {
                        ElementMoveFastColor {}
                    }
                }

                Rectangle {
                    anchors.fill: parent
                    radius: Appearance.sizes.artworkRadius
                    visible: !root.compactCover
                    color: Qt.rgba(0, 0, 0, root.coverHovered && Player.hasSong ? 0.25 : 0)

                    Behavior on color {
                        ColorAnimation { duration: Appearance.duration(160) }
                    }
                }
            }
        }

        Item {
            id: overlayBox
            readonly property real bleed: root.compactCover ? 16 : 24
            readonly property real blurReach: Math.round(Math.min(root.coverHeight, Math.max(metadataColumn.implicitHeight, overlayButtons.implicitHeight) + 72))
            property real targetSigma: Appearance.performanceMode ? 0 : (root.coverHovered ? 1.2 : 9.5)
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: root.compactCover ? artworkStage.height : Math.round(Math.min(artworkStage.height, blurReach + bleed))
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
                property real uniformBlur: root.compactCover ? 1 : 0
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
                property real uniformBlur: root.compactCover ? 1 : 0
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

            Column {
                id: metadataColumn
                anchors.left: parent.left
                anchors.leftMargin: 32
                anchors.right: overlayButtons.left
                anchors.rightMargin: 8
                y: root.compactCover
                   ? Math.round(artwork.y - overlayBox.y + (artwork.height - implicitHeight) / 2)
                   : Math.round(overlayBox.height - overlayBox.bleed - 12 - implicitHeight)
                spacing: 2

                StyledText {
                    id: titleText
                    width: parent.width
                    text: Player.currentSong.name
                    elide: Text.ElideRight
                    font.pixelSize: Appearance.fontSize.normal
                    font.weight: Font.Bold
                    color: "white"
                }
                StyledText {
                    id: artistText
                    width: parent.width
                    text: Player.currentSong.artists
                    elide: Text.ElideRight
                    font.pixelSize: Appearance.fontSize.smallie
                    color: Qt.rgba(1, 1, 1, 0.82)
                }
            }

            Item {
                x: metadataColumn.x
                y: metadataColumn.y
                width: Math.min(metadataColumn.width, Math.max(titleText.implicitWidth, artistText.implicitWidth))
                height: metadataColumn.implicitHeight

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
            x: root.compactCover
               ? artwork.x + artwork.width - width - 10
               : Math.round(artwork.x + (artwork.width - width) / 2)
            y: root.compactCover
               ? artwork.y + 8
               : Math.round(artwork.y + (artwork.height - height) / 2)
            text: "open_in_full"
            iconSize: root.compactCover ? 18 : 28
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

            ArtworkImage {
                id: nextArt
                x: 8
                anchors.verticalCenter: parent.verticalCenter
                width: 38
                height: 38
                radius: Appearance.sizes.smallArtworkRadius
                source: root.nextSong.artworkUrl
                crossfade: true
            }

            Column {
                anchors.left: nextArt.right
                anchors.leftMargin: 10
                anchors.right: nextBadge.left
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                spacing: 1

                StyledText {
                    width: parent.width
                    text: root.nextSong.name
                    elide: Text.ElideRight
                    font.pixelSize: Appearance.fontSize.smallie
                    font.weight: Font.DemiBold
                    color: root.scheme.onSurface
                }
                StyledText {
                    width: parent.width
                    text: root.nextSong.artists
                    elide: Text.ElideRight
                    font.pixelSize: Appearance.fontSize.smaller
                    color: root.scheme.onSurfaceVariant
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

            StyledText {
                anchors.left: prevIcon.right
                anchors.leftMargin: 6
                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.StyledText
                maximumLineCount: 1
                text: root.previousSong.artists.length > 0
                      ? "<b>" + root.escapeHtml(root.previousSong.name) + "</b> - " + root.escapeHtml(root.previousSong.artists)
                      : "<b>" + root.escapeHtml(root.previousSong.name) + "</b>"
                elide: Text.ElideRight
                font.pixelSize: Appearance.fontSize.smaller
                color: prevButton.hovered ? root.scheme.onSurface : root.scheme.onSurfaceVariant

                Behavior on color {
                    ElementMoveFastColor {}
                }
            }
        }

        HoverHandler {
            cursorShape: prevButton.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        }
    }
}
