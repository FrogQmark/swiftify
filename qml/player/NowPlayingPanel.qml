pragma ComponentBehavior: Bound
import QtQuick
import Swiftify

// Now Playing (NowPlayingPanel): the song's cover large at the top of the side
// sheet, as the spotify client has it, the title, artists and album under it,
// and the lyrics below those. soft blurred shapes in the cover's colours drift
// behind it all while music plays. the cover opens the immersive player;
// the names go to their pages.
Item {
    id: root

    property MaterialScheme scheme: Appearance.colors
    /// under the immersive player: nothing moves, nothing scrolls
    property bool suspended: false
    signal immersiveRequested()

    readonly property bool lyricsMaximized: Settings.nowPlayingLyricsMaximized

    readonly property string kickerText: {
        if (!Player.hasSong) {
            return ""
        }
        switch (Player.contextType) {
        case "playlist":
            return qsTr("Playing from playlist")
        case "album":
            return qsTr("Playing from album")
        case "artist":
            return qsTr("Playing from artist")
        case "search":
            return qsTr("Playing from search")
        case "saved":
            return qsTr("Playing from playlist")
        case "local":
            return qsTr("Playing from local files")
        case "home":
            return qsTr("Playing from home")
        case "stats":
            return qsTr("Playing from stats")
        default:
            return Player.currentSong.albumName.length > 0 ? qsTr("Playing from album") : qsTr("Now Playing")
        }
    }

    readonly property string contextTitleText: {
        if (!Player.hasSong) {
            return qsTr("Now Playing")
        }
        if (Player.contextName.length > 0) {
            return Player.contextName
        }
        if (Player.currentSong.albumName.length > 0) {
            return Player.currentSong.albumName
        }
        return qsTr("Now Playing")
    }

    readonly property bool isContextClickable: {
        if (!Player.hasSong) {
            return false
        }
        if (Player.contextType === "playlist") {
            return Player.contextId.length > 0
        }
        if (Player.contextType === "album" || Player.contextType === "artist") {
            return !Player.currentSong.isLocalFile
        }
        if (Player.contextType === "search" || Player.contextType === "saved" || Player.contextType === "local" || Player.contextType === "home" || Player.contextType === "stats") {
            return true
        }
        return !Player.currentSong.isLocalFile && Player.currentSong.albumName.length > 0
    }

    function navigateToContext() {
        switch (Player.contextType) {
        case "playlist":
            if (Player.contextId.length > 0) {
                Library.selectPlaylistById(Player.contextId)
            }
            break
        case "album":
            if (Player.hasSong && !Player.currentSong.isLocalFile) {
                Library.goToAlbum(Player.currentSong)
            }
            break
        case "artist":
            if (Player.hasSong && !Player.currentSong.isLocalFile) {
                Library.goToArtist(Player.currentSong)
            }
            break
        case "search":
            Library.showSearch()
            break
        case "saved":
            Library.showSavedSongs()
            break
        case "local":
            Library.showLocalTracks()
            break
        case "home":
            Library.showHome()
            break
        case "stats":
            Library.showStats()
            break
        default:
            if (Player.hasSong && !Player.currentSong.isLocalFile) {
                Library.goToAlbum(Player.currentSong)
            }
            break
        }
    }

    clip: true

    function shade(index: int): color {
        const palette = PlayerStyle.palette
        return palette.length > 0 ? palette[index % palette.length] : root.scheme.primary
    }

    // the drifting shapes: sdf blurs, no layer, each on a slow loop of its
    // own. they follow the shared spin, so they move only while music plays
    // in a window that shows them
    Item {
        id: blobs
        anchors.fill: parent
        visible: Player.hasSong
        opacity: 0.7

        Repeater {
            model: [
                { "size": 0.95, "cx": 0.30, "cy": 0.18, "ax": 0.22, "ay": 0.10, "fx": 0.17, "fy": 0.26, "phase": 0.0 },
                { "size": 0.80, "cx": 0.72, "cy": 0.40, "ax": 0.18, "ay": 0.16, "fx": 0.20, "fy": 0.14, "phase": 2.1 },
                { "size": 0.85, "cx": 0.35, "cy": 0.68, "ax": 0.20, "ay": 0.12, "fx": 0.11, "fy": 0.19, "phase": 4.2 },
                { "size": 0.70, "cx": 0.65, "cy": 0.88, "ax": 0.16, "ay": 0.08, "fx": 0.23, "fy": 0.15, "phase": 1.3 }
            ]

            delegate: SoftShadow {
                required property var modelData
                required property int index

                readonly property real t: root.suspended || !root.visible ? 0 : UiState.spin
                readonly property real side: blobs.width * modelData.size

                width: side
                height: side
                radius: side / 2
                blur: blobs.width * 0.22
                color: root.shade(index)
                x: blobs.width * (modelData.cx + modelData.ax * Math.sin(t * modelData.fx + modelData.phase)) - side / 2
                y: blobs.height * (modelData.cy + modelData.ay * Math.cos(t * modelData.fy + modelData.phase)) - side / 2

                Behavior on color {
                    ColorAnimation { duration: Appearance.duration(900); easing.type: Easing.InOutSine }
                }
            }
        }
    }

    // the shapes sit under a veil of the sheet's own colour, so the text over
    // them keeps its contrast
    Rectangle {
        anchors.fill: parent
        radius: Appearance.rounding.large
        color: Qt.alpha(Appearance.colors.layer1, 0.35)
    }

    Column {
        id: header
        x: 18
        y: 16
        width: parent.width - 36 - (Settings.windowControlsOnRight ? 96 : 0)
        spacing: 2

        StyledText {
            width: parent.width
            text: root.kickerText
            font.pixelSize: 10
            font.weight: Font.DemiBold
            font.capitalization: Font.AllUppercase
            color: root.scheme.onSurfaceVariant
            elide: Text.ElideRight
            visible: text.length > 0
        }

        StyledText {
            id: contextTitle
            width: parent.width
            text: root.contextTitleText
            font.pixelSize: Appearance.fontSize.normal
            font.weight: Font.DemiBold
            color: root.scheme.onSurface
            elide: Text.ElideRight
            font.underline: headerHover.hovered && root.isContextClickable

            HoverHandler {
                id: headerHover
                enabled: root.isContextClickable
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            }
            TapHandler {
                enabled: root.isContextClickable
                onTapped: root.navigateToContext()
            }
        }
    }

    Column {
        id: info
        anchors.top: header.bottom
        anchors.topMargin: 12
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.max(120, Math.min(root.width - 32, root.height * 0.38))
        spacing: 4
        visible: Player.hasSong

        Item {
            id: cover
            width: parent.width
            height: root.lyricsMaximized ? 0 : width
            visible: !root.lyricsMaximized
            clip: true

            SoftShadow {
                anchors.fill: parent
                radius: Appearance.sizes.artworkRadius
                blur: 16
                offset: Qt.vector2d(0, 6)
                color: Qt.rgba(0, 0, 0, 0.3)
            }

            ArtworkImage {
                anchors.fill: parent
                source: Player.currentSong.artworkUrl
                crossfade: true
            }

            Rectangle {
                anchors.fill: parent
                radius: Appearance.sizes.artworkRadius
                color: Qt.rgba(0, 0, 0, coverHover.hovered ? 0.25 : 0)

                Behavior on color {
                    ColorAnimation { duration: Appearance.duration(160) }
                }

                MaterialSymbol {
                    anchors.centerIn: parent
                    text: "open_in_full"
                    iconSize: 28
                    weight: 600
                    color: "white"
                    opacity: coverHover.hovered ? 1 : 0
                }
            }

            HoverHandler {
                id: coverHover
                cursorShape: Qt.PointingHandCursor
            }
            TapHandler {
                onTapped: root.immersiveRequested()
            }
        }

        Item {
            width: 1
            height: root.lyricsMaximized ? 0 : 8
            visible: !root.lyricsMaximized
        }

        Row {
            width: parent.width
            spacing: 8

            Column {
                width: parent.width - maximizeButton.width - parent.spacing
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

                TitleText {
                    width: parent.width
                    text: Player.currentSong.name
                    elide: Text.ElideRight
                    color: root.scheme.onSurface
                    font.underline: titleHover.hovered && !Player.currentSong.isLocalFile

                    HoverHandler {
                        id: titleHover
                        cursorShape: Player.currentSong.isLocalFile ? Qt.ArrowCursor : Qt.PointingHandCursor
                    }
                    TapHandler {
                        onTapped: if (!Player.currentSong.isLocalFile) Library.goToAlbum(Player.currentSong)
                    }
                }

                StyledText {
                    width: parent.width
                    text: Format.joined([Player.currentSong.artists, Player.currentSong.albumName], " — ")
                    elide: Text.ElideRight
                    font.pixelSize: Appearance.fontSize.small
                    color: root.scheme.onSurfaceVariant
                    font.underline: artistHover.hovered && !Player.currentSong.isLocalFile

                    HoverHandler {
                        id: artistHover
                        cursorShape: Player.currentSong.isLocalFile ? Qt.ArrowCursor : Qt.PointingHandCursor
                    }
                    TapHandler {
                        onTapped: if (!Player.currentSong.isLocalFile) Library.goToArtist(Player.currentSong)
                    }
                }
            }

            IconButton {
                id: maximizeButton
                objectName: "maximizeLyricsButton"
                anchors.verticalCenter: parent.verticalCenter
                scheme: root.scheme
                size: 32
                iconSize: 20
                symbol: root.lyricsMaximized ? "close_fullscreen" : "open_in_full"
                tooltip: root.lyricsMaximized ? qsTr("Restore") : qsTr("Maximize")
                onClicked: Settings.nowPlayingLyricsMaximized = !Settings.nowPlayingLyricsMaximized
            }
        }
    }

    // the lyrics fill what is left under the song
    LyricsPanel {
        id: lyrics
        anchors.top: info.bottom
        anchors.topMargin: 8
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: queueFooter.visible ? queueFooter.top : parent.bottom
        anchors.bottomMargin: queueFooter.visible ? 8 : 0
        visible: Player.hasSong
        suspended: root.suspended || !root.visible
        scheme: root.scheme
    }

    Rectangle {
        id: queueFooter
        anchors.left: parent.left
        anchors.leftMargin: 16
        anchors.right: parent.right
        anchors.rightMargin: 16
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 14
        radius: 12
        color: Qt.alpha(root.scheme.surfaceContainerHighest, 0.4)
        visible: Player.hasSong && !root.lyricsMaximized && (Player.hasNextSong || Player.hasPreviousSong)
        height: queueContent.implicitHeight + 16

        Column {
            id: queueContent
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8

            Column {
                width: parent.width
                spacing: 6
                visible: Player.hasNextSong

                StyledText {
                    width: parent.width
                    text: qsTr("Next in queue")
                    font.pixelSize: 10
                    font.weight: Font.DemiBold
                    font.capitalization: Font.AllUppercase
                    color: root.scheme.onSurfaceVariant
                    elide: Text.ElideRight
                }

                Item {
                    id: nextSongRow
                    width: parent.width
                    height: 38

                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: -4
                        radius: 6
                        color: nextSongHover.hovered ? Qt.alpha(root.scheme.onSurface, 0.06) : "transparent"
                    }

                    HoverHandler {
                        id: nextSongHover
                        cursorShape: Qt.PointingHandCursor
                    }
                    TapHandler {
                        onTapped: Player.skipForward()
                    }

                    ArtworkImage {
                        id: nextArt
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        width: 36
                        height: 36
                        radius: 4
                        source: Player.nextSong.artworkUrl
                    }

                    Column {
                        anchors.left: nextArt.right
                        anchors.leftMargin: 10
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2

                        StyledText {
                            width: parent.width
                            text: Player.nextSong.name
                            font.pixelSize: Appearance.fontSize.small
                            font.weight: Font.DemiBold
                            color: root.scheme.onSurface
                            elide: Text.ElideRight
                        }

                        StyledText {
                            width: parent.width
                            text: Player.nextSong.artists
                            font.pixelSize: Appearance.fontSize.smaller
                            color: root.scheme.onSurfaceVariant
                            elide: Text.ElideRight
                        }
                    }
                }
            }

            Rectangle {
                width: parent.width
                height: 1
                color: root.scheme.outlineVariant
                opacity: 0.25
                visible: Player.hasNextSong && Player.hasPreviousSong
            }

            Item {
                id: previousSongRow
                width: parent.width
                height: 18
                visible: Player.hasPreviousSong

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: -3
                    radius: 4
                    color: prevSongHover.hovered ? Qt.alpha(root.scheme.onSurface, 0.06) : "transparent"
                }

                HoverHandler {
                    id: prevSongHover
                    cursorShape: Qt.PointingHandCursor
                }
                TapHandler {
                    onTapped: Player.skipToPreviousSong()
                }

                Row {
                    anchors.fill: parent
                    spacing: 6

                    ArtworkImage {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 14
                        height: 14
                        radius: 2
                        source: Player.previousSong.artworkUrl
                    }

                    StyledText {
                        width: parent.width - 20
                        anchors.verticalCenter: parent.verticalCenter
                        text: Player.previousSong.name
                        font.pixelSize: Appearance.fontSize.smaller
                        color: root.scheme.onSurfaceVariant
                        elide: Text.ElideRight
                    }
                }
            }
        }
    }

    EmptyState {
        anchors.centerIn: parent
        width: parent.width - 32
        Reveal.shown: !Player.hasSong
        symbol: "album"
        title: "Nothing Playing"
        description: "Play a song and its cover shows here."
    }
}
