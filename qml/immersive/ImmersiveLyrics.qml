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
    readonly property real renderScale: Math.max(1.0, root.Window.window ? root.Window.window.devicePixelRatio : 1.0)

    // Smooth sub-250ms position driven off UiState.spin only while playing and
    // visible, so an idle or paused window draws nothing at rest.
    property real anchorPositionMs: Player.livePositionMs
    property double anchorWallMs: Date.now()
    property real displayPositionMs: Player.livePositionMs

    component SweepGlyph: Item {
        id: glyph

        property string text: ""
        property int fontSize: 30
        property int fontWeight: Font.Bold
        property bool lineActive: false
        property real progress: 0
        property real glowStrength: 0
        property real feather: 0.22

        implicitWidth: mainText.implicitWidth
        implicitHeight: mainText.implicitHeight

        // Per-word / per-letter subtle glow behind actively sung text
        StyledText {
            visible: glyph.glowStrength > 0.01 && !Appearance.performanceMode
            text: glyph.text
            font.pixelSize: glyph.fontSize
            font.weight: glyph.fontWeight
            color: PlayerStyle.primary
            opacity: glyph.glowStrength * 0.35
            layer.enabled: visible
            layer.smooth: true
            layer.effect: MultiEffect {
                blurEnabled: true
                blur: 0.55
                blurMax: 14
            }
        }

        StyledText {
            id: mainText
            text: glyph.text
            font.pixelSize: glyph.fontSize
            font.weight: glyph.fontWeight
            color: "white"
            opacity: (layer.enabled || !glyph.lineActive || !Player.lyricsSynchronized || glyph.progress >= 1) ? 1.0 : 0.36

            layer.enabled: glyph.lineActive && Player.lyricsSynchronized && !Appearance.performanceMode
                && glyph.progress > 0 && glyph.progress < 1
            layer.smooth: true
            layer.textureSize: Qt.size(Math.max(1, Math.ceil(Math.max(mainText.width, mainText.implicitWidth) * root.renderScale * 2.0)),
                                       Math.max(1, Math.ceil(Math.max(mainText.height, mainText.implicitHeight) * root.renderScale * 2.0)))
            layer.effect: ShaderEffect {
                property variant source
                property color glowColor: Qt.rgba(PlayerStyle.primary.r, PlayerStyle.primary.g, PlayerStyle.primary.b, 1.0)
                property real progress: glyph.progress
                property real feather: glyph.feather
                property real baseAlpha: 0.36
                property real glowBoost: glyph.glowStrength
                property real vertical: 0.0
                property real spanStart: 0.0
                property real spanEnd: 1.0
                fragmentShader: "qrc:/shaders/lyric_sweep.frag.qsb"
            }
        }

        // Plain clip wipe fallback when Performance Mode disables shaders
        Item {
            clip: true
            width: glyph.width * glyph.progress
            height: glyph.height
            visible: Appearance.performanceMode && glyph.lineActive && Player.lyricsSynchronized
                && glyph.progress > 0 && glyph.progress < 1 && width > 0

            StyledText {
                text: glyph.text
                font.pixelSize: glyph.fontSize
                font.weight: glyph.fontWeight
                color: "white"
            }
        }
    }

    component SyllableLines: Item {
        id: wrapBox

        property var wordGroupsModel: []
        property bool rightAligned: false
        property bool lineActive: false
        property int fontSize: 30
        property int fontWeight: Font.Bold
        property real spacingX: 9
        property real spacingY: 4
        property bool enableLift: true
        property int longSyllableMinMs: 750
        readonly property real liftFactor: Math.max(0.55, fontSize / 30.0)
        property real contentHeight: 0

        implicitHeight: contentHeight
        height: contentHeight

        function splitLetters(text: string) {
            // Avoid splitting complex Arabic/Indic shaping or combining marks mid-cluster
            for (let i = 0; i < text.length; ++i) {
                const code = text.charCodeAt(i)
                if ((code >= 0x0590 && code <= 0x06FF) || (code >= 0x0900 && code <= 0x0DFF) || (code >= 0x0300 && code <= 0x036F)) {
                    return []
                }
            }
            return text.length > 1 ? text.split("") : []
        }

        function layoutWords() {
            const maxWidth = width
            const total = wordRepeater.count
            if (maxWidth <= 0 || total <= 0) {
                contentHeight = 0
                return
            }
            let y = 0
            let rowStart = 0
            let rowWidth = 0
            let rowHeight = 0
            let rowCount = 0

            for (let i = 0; i <= total; ++i) {
                let itemWidth = 0
                let itemHeight = 0
                let hasItem = false
                let flush = (i === total)
                if (i < total) {
                    const probe = wordRepeater.itemAt(i)
                    if (probe) {
                        itemWidth = probe.implicitWidth
                        itemHeight = probe.implicitHeight
                        hasItem = true
                        if (rowCount > 0 && rowWidth + spacingX + itemWidth > maxWidth) {
                            flush = true
                        }
                    }
                }
                if (flush && rowCount > 0) {
                    let x = rightAligned ? Math.max(0, maxWidth - rowWidth) : 0
                    for (let j = rowStart; j < i; ++j) {
                        const word = wordRepeater.itemAt(j)
                        if (word) {
                            word.x = x
                            word.y = y + (rowHeight - word.implicitHeight) / 2
                            x += word.implicitWidth + spacingX
                        }
                    }
                    y += rowHeight + spacingY
                    rowStart = i
                    rowWidth = 0
                    rowHeight = 0
                    rowCount = 0
                }
                if (hasItem) {
                    rowWidth = rowCount > 0 ? rowWidth + spacingX + itemWidth : itemWidth
                    rowHeight = Math.max(rowHeight, itemHeight)
                    rowCount += 1
                }
            }
            contentHeight = y > 0 ? y - spacingY : 0
        }

        onWidthChanged: layoutWords()
        onRightAlignedChanged: layoutWords()
        onWordGroupsModelChanged: Qt.callLater(layoutWords)
        Component.onCompleted: layoutWords()

        Repeater {
            id: wordRepeater
            model: wrapBox.wordGroupsModel
            onItemAdded: Qt.callLater(wrapBox.layoutWords)
            onItemRemoved: Qt.callLater(wrapBox.layoutWords)

            delegate: Row {
                id: wordRow
                required property var modelData
                spacing: 0
                onImplicitWidthChanged: Qt.callLater(wrapBox.layoutWords)
                onImplicitHeightChanged: Qt.callLater(wrapBox.layoutWords)

                Repeater {
                    model: wordRow.modelData

                    delegate: Item {
                        id: sylItem
                        required property var modelData
                        readonly property string sylText: modelData && modelData.text !== undefined ? String(modelData.text) : ""
                        readonly property real startMs: modelData ? Number(modelData.startTimeMs) : 0
                        readonly property real endMs: Math.max(startMs + 1, modelData ? Number(modelData.endTimeMs) : 1)
                        readonly property real durationMs: Math.max(1, endMs - startMs)
                        readonly property real progress: !Player.lyricsSynchronized ? 1
                            : !wrapBox.lineActive ? (root.displayPositionMs >= endMs ? 1 : 0)
                            : Math.max(0, Math.min(1, (root.displayPositionMs - startMs) / durationMs))
                        readonly property bool singing: wrapBox.lineActive && progress > 0 && progress < 1
                        readonly property bool longSyllable: wrapBox.enableLift && durationMs >= wrapBox.longSyllableMinMs && sylText.length > 1
                            && !Appearance.reduceMotion && !Appearance.performanceMode
                        readonly property var letters: longSyllable ? wrapBox.splitLetters(sylText) : []
                        readonly property bool useLetters: letters.length > 1

                        property real wordGlow: !Appearance.performanceMode && wrapBox.lineActive && singing ? 1.0 : 0.0
                        property real lift: (wrapBox.enableLift && !useLetters && !Appearance.reduceMotion && !Appearance.performanceMode && wrapBox.lineActive)
                            ? (singing ? -2.0 * wrapBox.liftFactor : (progress >= 1 ? -0.5 * wrapBox.liftFactor : 0))
                            : 0
                        property real wordScale: (wrapBox.enableLift && !useLetters && !Appearance.reduceMotion && !Appearance.performanceMode && wrapBox.lineActive && singing)
                            ? 1.04 : 1.0

                        implicitWidth: useLetters ? letterRow.implicitWidth : singleGlyph.implicitWidth
                        implicitHeight: useLetters ? letterRow.implicitHeight : singleGlyph.implicitHeight
                        scale: wordScale
                        transform: Translate { y: sylItem.lift }

                        Behavior on wordGlow {
                            enabled: !Appearance.performanceMode
                            NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
                        }
                        Behavior on lift {
                            enabled: wrapBox.enableLift && !Appearance.reduceMotion && !Appearance.performanceMode
                            NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
                        }
                        Behavior on wordScale {
                            enabled: wrapBox.enableLift && !Appearance.reduceMotion && !Appearance.performanceMode
                            NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
                        }

                        SweepGlyph {
                            id: singleGlyph
                            visible: !sylItem.useLetters
                            text: sylItem.sylText
                            fontSize: wrapBox.fontSize
                            fontWeight: wrapBox.fontWeight
                            lineActive: wrapBox.lineActive
                            progress: sylItem.progress
                            glowStrength: sylItem.wordGlow
                            feather: 0.24
                        }

                        Row {
                            id: letterRow
                            visible: sylItem.useLetters
                            spacing: 0

                            Repeater {
                                model: sylItem.useLetters ? sylItem.letters : []

                                delegate: Item {
                                    id: letterItem
                                    required property int index
                                    required property string modelData
                                    readonly property int letterCount: Math.max(1, sylItem.letters.length)
                                    readonly property real window: Math.min(0.45, 1.5 / letterCount)
                                    readonly property real lStart: letterCount > 1 ? (index / (letterCount - 1)) * (1.0 - window) : 0
                                    readonly property real lProgress: !Player.lyricsSynchronized ? 1
                                        : !wrapBox.lineActive ? (root.displayPositionMs >= sylItem.endMs ? 1 : 0)
                                        : Math.max(0, Math.min(1, (sylItem.progress - lStart) / Math.max(0.01, window)))
                                    readonly property real wave: wrapBox.lineActive && sylItem.singing ? Math.sin(lProgress * Math.PI) : 0
                                    readonly property bool activeLetter: wrapBox.lineActive && sylItem.singing && lProgress > 0 && lProgress < 1

                                    property real letterGlow: activeLetter ? 1.0 : (wrapBox.lineActive && sylItem.singing && lProgress >= 1 ? 0.55 : 0.0)
                                    property real letterLift: wrapBox.lineActive && sylItem.singing
                                        ? ((-5.5 * wave - (lProgress >= 1 ? 1.5 : 0)) * wrapBox.liftFactor)
                                        : (wrapBox.lineActive && sylItem.progress >= 1 ? -0.5 * wrapBox.liftFactor : 0)
                                    property real letterScale: wrapBox.lineActive && sylItem.singing
                                        ? (1.0 + 0.16 * wave + 0.03) : 1.0

                                    implicitWidth: letterGlyph.implicitWidth
                                    implicitHeight: letterGlyph.implicitHeight
                                    scale: letterScale
                                    transform: Translate { y: letterItem.letterLift }

                                    Behavior on letterGlow {
                                        NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
                                    }
                                    Behavior on letterLift {
                                        NumberAnimation { duration: 90; easing.type: Easing.OutCubic }
                                    }
                                    Behavior on letterScale {
                                        NumberAnimation { duration: 90; easing.type: Easing.OutCubic }
                                    }

                                    SweepGlyph {
                                        id: letterGlyph
                                        text: letterItem.modelData
                                        fontSize: wrapBox.fontSize
                                        fontWeight: wrapBox.fontWeight
                                        lineActive: wrapBox.lineActive
                                        progress: letterItem.lProgress
                                        glowStrength: letterItem.letterGlow
                                        feather: 0.35
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

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
            required property string translatedWords
            required property var translationWordGroups
            required property bool oppositeAligned
            required property bool instrumental
            required property var wordGroups
            required property var backgroundVocals

            readonly property bool active: !Player.lyricsSynchronized || Player.activeLyricIndex === index
            readonly property bool hasSyllables: !instrumental && wordGroups !== undefined && wordGroups !== null && wordGroups.length > 0
            readonly property bool hasRomanized: !instrumental && Settings.spicyLyricsRomanized && romanizedWords.length > 0
            readonly property bool hasTranslation: !instrumental && Settings.spicyLyricsTranslated && translatedWords.length > 0
            readonly property bool hasTranslationWords: hasTranslation && translationWordGroups !== undefined && translationWordGroups !== null && translationWordGroups.length > 0
            readonly property bool hasBackground: !instrumental && backgroundVocals !== undefined && backgroundVocals !== null && backgroundVocals.length > 0
            readonly property real lineProgress: !Player.lyricsSynchronized ? 1
                : !active ? (root.displayPositionMs >= endTimeMs ? 1 : 0)
                : Math.max(0, Math.min(1, (root.displayPositionMs - startTimeMs) / Math.max(1, endTimeMs - startTimeMs)))
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
                const mainHeight = hasSyllables ? leadSyllables.implicitHeight + 28 : label.implicitHeight
                const extraHeight = (hasRomanized || hasTranslation || hasBackground) ? extraCol.implicitHeight + 10 : 0
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

            // the sung line sits on a dark tinted scalloped pill for contrast
            WavyPill {
                objectName: "lyricHighlight"
                anchors.fill: parent
                cornerRadius: 32
                color: Qt.rgba(0, 0, 0, line.active && Player.lyricsSynchronized ? 0.28 : 0)

                Behavior on color {
                    ColorAnimation { duration: Appearance.duration(320); easing.type: Easing.InOutQuad }
                }
            }

            Rectangle {
                anchors.fill: parent
                radius: 20
                color: Qt.rgba(0, 0, 0, line.highlighted ? 0.22 : 0)

                Behavior on color {
                    ColorAnimation { duration: Appearance.duration(180); easing.type: Easing.OutQuad }
                }
            }

            Item {
                id: textContainer
                width: parent.width
                height: parent.height
                opacity: line.active ? 1 : 0.34

                Behavior on opacity {
                    NumberAnimation { duration: Appearance.duration(320); easing.type: Easing.InOutQuad }
                }

                // Only rasterize into a blur layer for inactive lines so active
                // lyrics, romanization, and translations stay razor-sharp.
                layer.enabled: line.nearViewport && line.blurStrength > 0.01 && !Appearance.performanceMode
                layer.smooth: true
                layer.textureSize: Qt.size(Math.max(1, Math.ceil(textContainer.width * root.renderScale)),
                                           Math.max(1, Math.ceil(textContainer.height * root.renderScale)))
                layer.effect: MultiEffect {
                    blurEnabled: true
                    blur: line.blurStrength
                    blurMax: 24
                }

                // Line-synced top-to-bottom progression & unsynced/test label
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
                    opacity: (layer.enabled || !line.active || !Player.lyricsSynchronized
                        || (!Player.playing && root.displayPositionMs === 0)
                        || line.lineProgress >= 1) ? 1.0 : 0.36

                    layer.enabled: line.active && !line.hasSyllables && !line.instrumental
                        && Player.lyricsSynchronized && !Appearance.performanceMode
                        && line.lineProgress > 0 && line.lineProgress < 1
                    layer.smooth: true
                    layer.textureSize: Qt.size(Math.max(1, Math.ceil(Math.max(label.width, label.implicitWidth) * root.renderScale * 2.0)),
                                               Math.max(1, Math.ceil(Math.max(label.height, label.implicitHeight) * root.renderScale * 2.0)))
                    layer.effect: ShaderEffect {
                        property variant source
                        property color glowColor: Qt.rgba(PlayerStyle.primary.r, PlayerStyle.primary.g, PlayerStyle.primary.b, 1.0)
                        property real progress: line.lineProgress
                        property real feather: 0.28
                        property real baseAlpha: 0.36
                        property real glowBoost: 0.55
                        property real vertical: 1.0
                        property real spanStart: Math.min(0.4, label.topPadding / Math.max(1, label.height))
                        property real spanEnd: Math.max(spanStart + 0.1, 1.0 - label.bottomPadding / Math.max(1, label.height))
                        fragmentShader: "qrc:/shaders/lyric_sweep.frag.qsb"
                    }
                }

                // Syllable-by-syllable karaoke layout (grouped by whole words so lines never split mid-word)
                SyllableLines {
                    id: leadSyllables
                    visible: line.hasSyllables
                    x: 24
                    y: 22
                    width: Math.max(0, parent.width - 48)
                    wordGroupsModel: line.hasSyllables ? line.wordGroups : []
                    rightAligned: line.oppositeAligned
                    lineActive: line.active
                    fontSize: 30
                    fontWeight: Font.Bold
                    spacingX: 9
                    spacingY: 4
                    enableLift: true
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

                // Romanized text, translation, and background vocals below the lead line
                Column {
                    id: extraCol
                    visible: line.hasRomanized || line.hasTranslation || line.hasBackground
                    x: 24
                    y: line.hasSyllables ? leadSyllables.implicitHeight + 30 : label.implicitHeight + 10
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

                    SyllableLines {
                        id: translationSyllables
                        visible: line.hasTranslationWords
                        width: parent.width
                        wordGroupsModel: line.hasTranslationWords ? line.translationWordGroups : []
                        rightAligned: line.oppositeAligned
                        lineActive: line.active
                        fontSize: 17
                        fontWeight: Font.Medium
                        spacingX: 6
                        spacingY: 3
                        enableLift: true
                        longSyllableMinMs: 950
                    }

                    StyledText {
                        visible: line.hasTranslation && !line.hasTranslationWords
                        width: parent.width
                        text: line.translatedWords
                        wrapMode: Text.Wrap
                        horizontalAlignment: line.oppositeAligned ? Text.AlignRight : Text.AlignLeft
                        font.pixelSize: 17
                        font.weight: Font.Medium
                        color: "white"
                        opacity: 0.85
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
                            readonly property string bgTranslated: modelData && modelData.translatedWords ? String(modelData.translatedWords) : ""
                            readonly property var bgTranslationWordGroups: modelData && modelData.translationWordGroups ? modelData.translationWordGroups : []
                            readonly property bool showBgTranslated: Settings.spicyLyricsTranslated && bgTranslated.length > 0
                            readonly property bool hasBgTranslationWords: showBgTranslated && bgTranslationWordGroups !== undefined && bgTranslationWordGroups !== null && bgTranslationWordGroups.length > 0
                            readonly property real bgStartMs: modelData ? Number(modelData.startTimeMs) : 0
                            readonly property real bgEndMs: Math.max(bgStartMs + 1, modelData ? Number(modelData.endTimeMs) : 1)
                            readonly property real bgProgress: !Player.lyricsSynchronized ? 1
                                : !line.active ? (root.displayPositionMs >= bgEndMs ? 1 : 0)
                                : Math.max(0, Math.min(1, (root.displayPositionMs - bgStartMs) / Math.max(1, bgEndMs - bgStartMs)))

                            width: extraCol.width
                            height: (hasBgSyllables ? bgSyllables.implicitHeight : bgText.implicitHeight)
                                + (showBgRomanized ? bgRomText.implicitHeight + 4 : 0)
                                + (showBgTranslated ? ((hasBgTranslationWords ? bgTransSyllables.implicitHeight : bgTransText.implicitHeight) + 4) : 0)
                            opacity: 0.78

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
                                opacity: (layer.enabled || !line.active || !Player.lyricsSynchronized
                                    || (!Player.playing && root.displayPositionMs === 0)
                                    || bgItem.bgProgress >= 1) ? 1.0 : 0.36

                                layer.enabled: line.active && !bgItem.hasBgSyllables
                                    && Player.lyricsSynchronized && !Appearance.performanceMode
                                    && bgItem.bgProgress > 0 && bgItem.bgProgress < 1
                                layer.smooth: true
                                layer.textureSize: Qt.size(Math.max(1, Math.ceil(Math.max(bgText.width, bgText.implicitWidth) * root.renderScale * 2.0)),
                                                           Math.max(1, Math.ceil(Math.max(bgText.height, bgText.implicitHeight) * root.renderScale * 2.0)))
                                layer.effect: ShaderEffect {
                                    property variant source
                                    property color glowColor: Qt.rgba(PlayerStyle.primary.r, PlayerStyle.primary.g, PlayerStyle.primary.b, 1.0)
                                    property real progress: bgItem.bgProgress
                                    property real feather: 0.28
                                    property real baseAlpha: 0.36
                                    property real glowBoost: 0.45
                                    property real vertical: 1.0
                                    property real spanStart: 0.0
                                    property real spanEnd: 1.0
                                    fragmentShader: "qrc:/shaders/lyric_sweep.frag.qsb"
                                }
                            }

                            SyllableLines {
                                id: bgSyllables
                                visible: bgItem.hasBgSyllables
                                width: parent.width
                                wordGroupsModel: bgItem.hasBgSyllables ? bgItem.bgWordGroups : []
                                rightAligned: line.oppositeAligned
                                lineActive: line.active
                                fontSize: 20
                                fontWeight: Font.DemiBold
                                spacingX: 7
                                spacingY: 3
                                enableLift: true
                            }

                            StyledText {
                                id: bgRomText
                                visible: bgItem.showBgRomanized
                                width: parent.width
                                y: (bgItem.hasBgSyllables ? bgSyllables.implicitHeight : bgText.implicitHeight) + 4
                                text: bgItem.bgRomanized
                                wrapMode: Text.Wrap
                                horizontalAlignment: line.oppositeAligned ? Text.AlignRight : Text.AlignLeft
                                font.pixelSize: 14
                                font.weight: Font.Normal
                                color: "white"
                                opacity: 0.7
                            }

                            SyllableLines {
                                id: bgTransSyllables
                                visible: bgItem.hasBgTranslationWords
                                width: parent.width
                                y: (bgItem.hasBgSyllables ? bgSyllables.implicitHeight : bgText.implicitHeight)
                                    + (bgItem.showBgRomanized ? bgRomText.implicitHeight + 4 : 0) + 4
                                wordGroupsModel: bgItem.hasBgTranslationWords ? bgItem.bgTranslationWordGroups : []
                                rightAligned: line.oppositeAligned
                                lineActive: line.active
                                fontSize: 15
                                fontWeight: Font.Normal
                                spacingX: 5
                                spacingY: 2
                                enableLift: true
                                longSyllableMinMs: 950
                            }

                            StyledText {
                                id: bgTransText
                                visible: bgItem.showBgTranslated && !bgItem.hasBgTranslationWords
                                width: parent.width
                                y: (bgItem.hasBgSyllables ? bgSyllables.implicitHeight : bgText.implicitHeight)
                                    + (bgItem.showBgRomanized ? bgRomText.implicitHeight + 4 : 0) + 4
                                text: bgItem.bgTranslated
                                wrapMode: Text.Wrap
                                horizontalAlignment: line.oppositeAligned ? Text.AlignRight : Text.AlignLeft
                                font.pixelSize: 15
                                font.weight: Font.Normal
                                color: "white"
                                opacity: 0.85
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
