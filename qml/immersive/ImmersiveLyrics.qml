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
import QtQuick.Effects
import Swiftify

// the immersive lyrics (FullscreenLyrics): large bold lines, the sung one
// bright and glowing in the cover's first colour, kept in the middle, the
// column fading out at its edges. supports syllable-level karaoke sweeps,
// duet alignment, background vocals, romanized lines, and instrumental breaks
// from Spicy Lyrics while keeping Spotify / LRC fallback intact.
Item {
    id: root

    property MaterialScheme scheme: PlayerStyle.darkScheme
    readonly property color glow: Qt.rgba(PlayerStyle.primary.r, PlayerStyle.primary.g, PlayerStyle.primary.b, 0.5)

    // Smooth sub-250ms position driven off UiState.spin only while playing and
    // visible, so an idle or paused window draws nothing at rest.
    property real anchorPositionMs: Player.livePositionMs
    property double anchorWallMs: Date.now()
    property real displayPositionMs: Player.livePositionMs

    function syncDisplayPosition() {
        anchorPositionMs = Player.livePositionMs
        anchorWallMs = Date.now()
        displayPositionMs = anchorPositionMs
    }

    onVisibleChanged: syncDisplayPosition()

    Connections {
        target: Player
        function onLivePositionMsChanged() { root.syncDisplayPosition() }
        function onPlayingChanged() { root.syncDisplayPosition() }
        function onLyricsChanged() { root.syncDisplayPosition() }
    }

    Connections {
        target: UiState
        enabled: root.visible && Player.playing && Player.lyricsSynchronized
        function onSpinChanged() {
            const elapsed = Math.max(0, Math.min(400, Date.now() - root.anchorWallMs))
            root.displayPositionMs = root.anchorPositionMs + elapsed
        }
    }

    Column {
        anchors.centerIn: parent
        Reveal.shown: Player.loadingLyrics
        spacing: 14

        LoadingSpinner {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 36
            height: 36
            color: root.scheme.primary
            trackColor: Qt.rgba(1, 1, 1, 0.12)
        }
        StyledText {
            text: qsTr("Loading lyrics…")
            color: Qt.rgba(1, 1, 1, 0.7)
        }
    }

    EmptyState {
        anchors.centerIn: parent
        Reveal.shown: !Player.loadingLyrics && !Player.hasLyrics
        scheme: root.scheme
        symbol: "lyrics"
        title: qsTr("Lyrics Unavailable")
        description: Player.lyricsMessage.length > 0 ? qsTranslate("Errors", Player.lyricsMessage) : UiState.catchphrase
    }

    ListView {
        id: list
        objectName: "immersiveLyricsList"
        anchors.fill: parent
        Reveal.shown: !Player.loadingLyrics && Player.hasLyrics
        model: Player.lyrics
        spacing: 26
        topMargin: 30
        bottomMargin: 30
        leftMargin: 8
        rightMargin: 8
        // dragged past either end, it stretches and springs back
        boundsBehavior: Flickable.DragAndOvershootBounds
        cacheBuffer: 1200
        // the fade hides lines scrolled past the edge, the clip keeps them
        // from taking clicks meant for the top bar
        clip: true
        // a step moves every line at once; each then springs from where it
        // was to its new place, the ones nearest the sung line first, so the
        // column arrives as a wave rather than a block
        signal stepped(real delta)

        layer.enabled: true
        layer.effect: ShaderEffect {
            property variant source
            property real edge: 0.08
            fragmentShader: "qrc:/shaders/edge_fade.frag.qsb"
        }

        function follow(animated: bool) {
            const index = Player.activeLyricIndex
            if (index < 0) {
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
            // with reduced motion the column scrolls there on a plain ease
            // out, every line together, rather than as a wave
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
        Component.onCompleted: Qt.callLater(list.follow, false)

        delegate: Item {
            id: line

            required property int index
            required property string words
            required property int startTimeMs
            required property int endTimeMs
            required property string romanizedWords
            required property bool oppositeAligned
            required property bool instrumental
            required property var wordGroups
            required property var backgroundVocals

            readonly property bool active: !Player.lyricsSynchronized || Player.activeLyricIndex === index
            readonly property bool hasSyllables: !instrumental && wordGroups !== undefined && wordGroups !== null && wordGroups.length > 0
            readonly property bool hasRomanized: !instrumental && Settings.spicyLyricsRomanized && romanizedWords.length > 0
            readonly property bool hasBackground: !instrumental && backgroundVocals !== undefined && backgroundVocals !== null && backgroundVocals.length > 0
            readonly property int distanceFromActive: Player.activeLyricIndex >= 0 ? Math.abs(index - Player.activeLyricIndex) : 0
            readonly property bool nearViewport: distanceFromActive <= 6

            property bool highlighted: false
            property real glowStrength: active ? 1 : 0
            property real blurStrength: !active && Player.lyricsSynchronized && !Appearance.performanceMode && nearViewport
                ? Math.min(0.42, 0.14 + distanceFromActive * 0.06)
                : 0

            Behavior on glowStrength {
                NumberAnimation { duration: Appearance.duration(320); easing.type: Easing.InOutQuad }
            }
            Behavior on blurStrength {
                NumberAnimation { duration: Appearance.duration(320); easing.type: Easing.InOutQuad }
            }

            width: list.width - list.leftMargin - list.rightMargin
            height: bodyHeight() + 16

            function bodyHeight(): real {
                if (instrumental) {
                    return instrumentalRow.implicitHeight + 28
                }
                const mainHeight = hasSyllables ? syllableFlow.implicitHeight + 28 : label.implicitHeight
                const extraHeight = (hasRomanized || hasBackground) ? extraCol.implicitHeight + 10 : 0
                return mainHeight + extraHeight
            }

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
                // a gentle ripple: a short stagger and a small overshoot
                PauseAnimation { duration: Math.min(Math.abs(line.index - Player.activeLyricIndex), 8) * 16 }
                NumberAnimation { target: line; property: "lag"; to: 0; duration: 560; easing.type: Easing.OutBack; easing.overshoot: 0.6 }
            }

            // the sung line swells a touch, on a spring, or with reduced
            // motion on the plain ease out the column scrolls with
            property real springing: active ? 1 : 0.96
            property real eased: active ? 1 : 0.96
            scale: Appearance.reduceMotion ? eased : springing
            transformOrigin: oppositeAligned ? Item.Right : Item.Left

            Behavior on springing {
                enabled: !Appearance.reduceMotion
                Bounce {}
            }
            Behavior on eased {
                enabled: Appearance.reduceMotion && !Appearance.performanceMode
                NumberAnimation { duration: 420; easing.type: Easing.OutCubic }
            }

            // the sung line sits on a scalloped pill
            WavyPill {
                objectName: "lyricHighlight"
                anchors.fill: parent
                cornerRadius: 32
                color: Qt.rgba(1, 1, 1, line.active && Player.lyricsSynchronized ? 0.07 : 0)

                Behavior on color {
                    ColorAnimation { duration: Appearance.duration(320); easing.type: Easing.InOutQuad }
                }
            }

            Rectangle {
                anchors.fill: parent
                radius: 20
                color: Qt.rgba(1, 1, 1, line.highlighted ? 0.13 : 0)

                Behavior on color {
                    ColorAnimation { duration: Appearance.duration(180); easing.type: Easing.OutQuad }
                }
            }

            Item {
                id: textContainer
                width: parent.width
                height: parent.height
                opacity: line.active ? 1 : 0.28

                Behavior on opacity {
                    NumberAnimation { duration: Appearance.duration(320); easing.type: Easing.InOutQuad }
                }

                layer.enabled: line.nearViewport && (line.glowStrength > 0.01 || line.blurStrength > 0.01)
                layer.effect: MultiEffect {
                    shadowEnabled: line.glowStrength > 0.01
                    shadowColor: root.glow
                    shadowOpacity: line.glowStrength
                    shadowBlur: 1
                    blurEnabled: line.blurStrength > 0.01 && !Appearance.performanceMode
                    blur: line.blurStrength
                    blurMax: 24
                    shadowHorizontalOffset: 0
                    shadowVerticalOffset: 0
                }

                // Kept visible for line-synced / unsynced lyrics and tests
                StyledText {
                    id: label
                    objectName: "lyricText"
                    visible: !line.hasSyllables && !line.instrumental
                    width: parent.width
                    y: 8
                    leftPadding: 24
                    rightPadding: 24
                    topPadding: 14
                    bottomPadding: 14
                    text: line.words.length > 0 ? line.words : "♪"
                    wrapMode: Text.Wrap
                    horizontalAlignment: line.oppositeAligned ? Text.AlignRight : Text.AlignLeft
                    font.pixelSize: 30
                    font.weight: Font.Bold
                    color: "white"
                }

                // Syllable-by-syllable karaoke layout (grouped by whole words so lines never split mid-word)
                Item {
                    visible: line.hasSyllables
                    x: 24
                    y: 22
                    width: Math.max(0, parent.width - 48)
                    height: syllableFlow.implicitHeight

                    Flow {
                        id: syllableFlow
                        width: line.oppositeAligned ? Math.min(implicitWidth, parent.width) : parent.width
                        anchors.right: line.oppositeAligned ? parent.right : undefined
                        spacing: 9

                        Repeater {
                            model: line.hasSyllables ? line.wordGroups : []

                            delegate: Row {
                                id: wordRow
                                required property var modelData
                                spacing: 0

                                Repeater {
                                    model: wordRow.modelData

                                    delegate: Item {
                                        id: sylItem
                                        required property var modelData
                                        readonly property real startMs: Number(modelData.startTimeMs)
                                        readonly property real endMs: Math.max(startMs + 1, Number(modelData.endTimeMs))
                                        readonly property real progress: !Player.lyricsSynchronized ? 1
                                            : !line.active ? (root.displayPositionMs >= endMs ? 1 : 0)
                                            : Math.max(0, Math.min(1, (root.displayPositionMs - startMs) / (endMs - startMs)))
                                        readonly property bool singing: line.active && progress > 0 && progress < 1
                                        readonly property real lift: (!Appearance.reduceMotion && !Appearance.performanceMode && line.active)
                                            ? (singing ? -2.0 : (progress >= 1 ? -0.5 : 0))
                                            : 0

                                        implicitWidth: baseSyl.implicitWidth
                                        implicitHeight: baseSyl.implicitHeight
                                        transform: Translate { y: sylItem.lift }

                                        Behavior on lift {
                                            enabled: !Appearance.reduceMotion && !Appearance.performanceMode
                                            NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
                                        }

                                        StyledText {
                                            id: baseSyl
                                            text: String(sylItem.modelData.text)
                                            font.pixelSize: 30
                                            font.weight: Font.Bold
                                            color: "white"
                                            opacity: line.active ? 0.36 : 1.0
                                        }

                                        Item {
                                            clip: true
                                            width: sylItem.width * sylItem.progress
                                            height: sylItem.height
                                            visible: line.active && width > 0

                                            StyledText {
                                                text: String(sylItem.modelData.text)
                                                font.pixelSize: 30
                                                font.weight: Font.Bold
                                                color: "white"
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Instrumental break dots
                Row {
                    id: instrumentalRow
                    visible: line.instrumental
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: 22
                    spacing: 14

                    readonly property real spanMs: Math.max(1, line.endTimeMs - line.startTimeMs)
                    readonly property real progress: line.active
                        ? Math.max(0, Math.min(1, (root.displayPositionMs - line.startTimeMs) / spanMs))
                        : 0

                    Repeater {
                        model: 3

                        delegate: Rectangle {
                            required property int index
                            readonly property real segmentStart: index / 3.0
                            readonly property real segmentProgress: Math.max(0, Math.min(1, (instrumentalRow.progress - segmentStart) * 3.0))
                            readonly property real pulse: line.active && Player.playing && !Appearance.reduceMotion
                                ? Math.sin(segmentProgress * Math.PI)
                                : 0

                            width: 12
                            height: 12
                            radius: 6
                            color: "white"
                            opacity: line.active ? (0.32 + 0.68 * segmentProgress) : 0.4
                            scale: 0.9 + 0.25 * pulse
                        }
                    }
                }

                // Romanized text and background vocals below the lead line
                Column {
                    id: extraCol
                    visible: line.hasRomanized || line.hasBackground
                    x: 24
                    y: line.hasSyllables ? syllableFlow.implicitHeight + 30 : label.implicitHeight + 10
                    width: Math.max(0, parent.width - 48)
                    spacing: 8

                    StyledText {
                        visible: line.hasRomanized
                        width: parent.width
                        text: line.romanizedWords
                        wrapMode: Text.Wrap
                        horizontalAlignment: line.oppositeAligned ? Text.AlignRight : Text.AlignLeft
                        font.pixelSize: 16
                        font.weight: Font.Medium
                        color: "white"
                        opacity: 0.72
                    }

                    Repeater {
                        model: line.hasBackground ? line.backgroundVocals : []

                        delegate: Item {
                            id: bgItem
                            required property var modelData
                            readonly property var bgWordGroups: modelData && modelData.wordGroups ? modelData.wordGroups : []
                            readonly property bool hasBgSyllables: bgWordGroups !== undefined && bgWordGroups !== null && bgWordGroups.length > 0
                            readonly property string bgRomanized: modelData && modelData.romanizedWords ? String(modelData.romanizedWords) : ""
                            readonly property bool showBgRomanized: Settings.spicyLyricsRomanized && bgRomanized.length > 0

                            width: extraCol.width
                            height: (hasBgSyllables ? bgFlow.implicitHeight : bgText.implicitHeight)
                                + (showBgRomanized ? bgRomText.implicitHeight + 4 : 0)
                            opacity: 0.75

                            StyledText {
                                id: bgText
                                visible: !bgItem.hasBgSyllables
                                width: parent.width
                                text: bgItem.modelData && bgItem.modelData.words ? String(bgItem.modelData.words) : ""
                                wrapMode: Text.Wrap
                                horizontalAlignment: line.oppositeAligned ? Text.AlignRight : Text.AlignLeft
                                font.pixelSize: 20
                                font.weight: Font.DemiBold
                                color: "white"
                            }

                            Flow {
                                id: bgFlow
                                visible: bgItem.hasBgSyllables
                                width: line.oppositeAligned ? Math.min(implicitWidth, parent.width) : parent.width
                                anchors.right: line.oppositeAligned ? parent.right : undefined
                                spacing: 7

                                Repeater {
                                    model: bgItem.hasBgSyllables ? bgItem.bgWordGroups : []

                                    delegate: Row {
                                        id: bgWordRow
                                        required property var modelData
                                        spacing: 0

                                        Repeater {
                                            model: bgWordRow.modelData

                                            delegate: Item {
                                                id: bgSylItem
                                                required property var modelData
                                                readonly property real startMs: Number(modelData.startTimeMs)
                                                readonly property real endMs: Math.max(startMs + 1, Number(modelData.endTimeMs))
                                                readonly property real progress: !Player.lyricsSynchronized ? 1
                                                    : !line.active ? (root.displayPositionMs >= endMs ? 1 : 0)
                                                    : Math.max(0, Math.min(1, (root.displayPositionMs - startMs) / (endMs - startMs)))

                                                implicitWidth: baseBgSyl.implicitWidth
                                                implicitHeight: baseBgSyl.implicitHeight

                                                StyledText {
                                                    id: baseBgSyl
                                                    text: String(bgSylItem.modelData.text)
                                                    font.pixelSize: 20
                                                    font.weight: Font.DemiBold
                                                    color: "white"
                                                    opacity: line.active ? 0.36 : 1.0
                                                }

                                                Item {
                                                    clip: true
                                                    width: bgSylItem.width * bgSylItem.progress
                                                    height: bgSylItem.height
                                                    visible: line.active && width > 0

                                                    StyledText {
                                                        text: String(bgSylItem.modelData.text)
                                                        font.pixelSize: 20
                                                        font.weight: Font.DemiBold
                                                        color: "white"
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            StyledText {
                                id: bgRomText
                                visible: bgItem.showBgRomanized
                                width: parent.width
                                y: (bgItem.hasBgSyllables ? bgFlow.implicitHeight : bgText.implicitHeight) + 4
                                text: bgItem.bgRomanized
                                wrapMode: Text.Wrap
                                horizontalAlignment: line.oppositeAligned ? Text.AlignRight : Text.AlignLeft
                                font.pixelSize: 14
                                font.weight: Font.Normal
                                color: "white"
                                opacity: 0.7
                            }
                        }
                    }
                }
            }

            Timer {
                id: flash
                interval: 80
                onTriggered: line.highlighted = false
            }

            MouseArea {
                anchors.fill: parent
                enabled: Player.lyricsSynchronized
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: {
                    line.highlighted = true
                    flash.restart()
                    Player.seekToLyricLine(line.index)
                }
            }
        }

        footer: StyledText {
            leftPadding: 18
            topPadding: 46
            text: qsTr("Lyrics provided by ") + Player.lyricsProvider
            font.pixelSize: Appearance.fontSize.smaller
            color: Qt.rgba(1, 1, 1, 0.4)
        }
    }
}
