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
import Swiftify

// Now Playing (NowPlayingPanel): full-width artwork with blurred metadata
// overlay, action buttons, and the lyrics column below it.
Item {
    id: root

    /// under the immersive player: the lines change, nothing scrolls
    property bool suspended: false
    property MaterialScheme scheme: Appearance.colors

    StyledText {
        id: header
        x: 18
        y: 16
        text: qsTr("Now Playing")
        font.pixelSize: Appearance.fontSize.normal
        font.weight: Font.DemiBold
        color: root.scheme.onSurfaceVariant
    }

    Item {
        id: artworkStage
        anchors.top: header.bottom
        anchors.topMargin: 12
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
                spacing: 2

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

                IconButton {
                    scheme: root.scheme
                    symbol: "open_in_full"
                    size: 32
                    iconSize: 16
                    iconColor: "white"
                    colBackgroundHover: Qt.rgba(1, 1, 1, 0.14)
                    tooltip: qsTr("Maximize lyrics")
                }
            }
        }
    }

    Item {
        id: lyricsArea
        anchors.top: Player.hasSong ? artworkStage.top : header.bottom
        anchors.topMargin: Player.hasSong ? artwork.height + 10 : 12
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
            spacing: 22
            topMargin: 8
            bottomMargin: 18
            leftMargin: 18
            rightMargin: 18
            clip: true
            boundsBehavior: Flickable.DragAndOvershootBounds
            cacheBuffer: 2000
            signal stepped(real delta)

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

                width: list.width - list.leftMargin - list.rightMargin
                height: text.implicitHeight

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
                    width: parent.width
                    transformOrigin: Item.TopLeft
                    text: line.words.length > 0 ? line.words : "♪"
                    wrapMode: Text.Wrap
                    font.pixelSize: 22
                    font.weight: Font.Bold
                    color: root.scheme.onSurface
                    property real springing: line.active ? 1 : 19 / 22
                    property real eased: line.active ? 1 : 19 / 22
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
