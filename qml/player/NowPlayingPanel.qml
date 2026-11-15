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
    readonly property bool hasNextSong: Player.hasSong && Player.upNext.count > 0
    readonly property song nextSong: Player.upNext.at(Player.upNext.count > 0 ? 0 : -1)

    StyledText {
        id: header
        x: 18
        y: Math.round((36 - implicitHeight) / 2)
        text: qsTr("Now Playing")
        font.pixelSize: Appearance.fontSize.smallie
        font.weight: Font.DemiBold
        color: root.scheme.onSurfaceVariant
    }

    Item {
        id: artworkStage
        anchors.top: parent.top
        anchors.topMargin: 36
        anchors.left: parent.left
        anchors.right: parent.right
        height: artwork.height + overlayBox.bleed
        visible: Player.hasSong

        Item {
            id: artworkContainer
            anchors.fill: parent

            Rectangle {
                anchors.fill: parent
                color: root.scheme.layer1
            }

            ArtworkImage {
                id: artwork
                x: 18
                y: 0
                width: Math.max(0, Math.round(parent.width - 36))
                height: width
                radius: Appearance.sizes.artworkRadius
                source: Player.currentSong.artworkUrl
                crossfade: true
            }

            Rectangle {
                anchors.fill: artwork
                radius: Appearance.sizes.artworkRadius
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
        }

        Item {
            id: overlayBox
            readonly property real bleed: 24
            readonly property real blurReach: Math.round(Math.max(metadataColumn.implicitHeight, overlayButtons.implicitHeight) + 72)
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: Math.round(Math.min(artworkStage.height, blurReach + bleed))
            visible: artwork.width > 0

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
                property real maxSigma: Appearance.performanceMode ? 0 : 9.5
                property real blurEndY: (overlayBox.height - overlayBox.bleed) / Math.max(1, overlayBox.height)
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
                property real maxSigma: Appearance.performanceMode ? 0 : 9.5
                property real blurEndY: (overlayBox.height - overlayBox.bleed) / Math.max(1, overlayBox.height)
                fragmentShader: "qrc:/shaders/progressive_blur.frag.qsb"
            }

            Column {
                id: metadataColumn
                anchors.left: parent.left
                anchors.leftMargin: 32
                anchors.right: overlayButtons.left
                anchors.rightMargin: 8
                anchors.bottom: parent.bottom
                anchors.bottomMargin: overlayBox.bleed + 12
                spacing: 2

                StyledText {
                    width: parent.width
                    text: Player.currentSong.name
                    elide: Text.ElideRight
                    font.pixelSize: Appearance.fontSize.normal
                    font.weight: Font.Bold
                    color: "white"
                }
                StyledText {
                    width: parent.width
                    text: Player.currentSong.artists
                    elide: Text.ElideRight
                    font.pixelSize: Appearance.fontSize.smallie
                    color: Qt.rgba(1, 1, 1, 0.82)
                }
            }

            Row {
                id: overlayButtons
                anchors.right: parent.right
                anchors.rightMargin: 26
                anchors.verticalCenter: metadataColumn.verticalCenter

                IconButton {
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
    }

    Rectangle {
        id: lyricsContainer
        anchors.top: Player.hasSong ? artworkStage.top : header.bottom
        anchors.topMargin: Player.hasSong ? artwork.height + 20 : 12
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: nextButton.visible ? nextButton.top : parent.bottom
        anchors.leftMargin: 18
        anchors.rightMargin: 18
        anchors.bottomMargin: nextButton.visible ? 10 : 18
        radius: Appearance.rounding.normal
        color: root.scheme.layer2
        clip: true

        Item {
            id: lyricsHeader
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.topMargin: 10
            anchors.leftMargin: 16
            anchors.rightMargin: 10
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
                symbol: "open_in_full"
                size: 30
                iconSize: 16
                tooltip: qsTr("Maximize lyrics")
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
                bottomMargin: 22
                leftMargin: 16
                rightMargin: 16
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

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: 18
        anchors.rightMargin: 18
        anchors.bottomMargin: 18
        height: 54
        visible: root.hasNextSong
        enabled: Player.canSkipForward
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
                color: root.scheme.primaryContainer
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
                    color: root.scheme.primaryContainer
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
                        speed: 40
                        period: 360
                    }
                }

                MaterialSymbol {
                    anchors.centerIn: parent
                    text: "skip_next"
                    iconSize: 20
                    color: nextButton.hovered && !burstAnim.running ? root.scheme.onPrimaryContainer : root.scheme.onSurfaceVariant

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
}
