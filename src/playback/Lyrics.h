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

#pragma once

#include <QAbstractListModel>
#include <QString>
#include <QStringList>
#include <QtQml/qqmlregistration.h>

#include <optional>

namespace swiftify {

struct LyricSyllable {
    quint32 startTimeMs = 0;
    quint32 endTimeMs = 0;
    QString text;
    QString romanizedText;
    bool isPartOfWord = false;
};

struct LyricVocalGroup {
    quint32 startTimeMs = 0;
    quint32 endTimeMs = 0;
    QString words;
    QString romanizedWords;
    QString translatedWords;
    QList<LyricSyllable> syllables;
};

struct LyricLine {
    quint32 startTimeMs = 0;
    quint32 endTimeMs = 0;
    QString words;
    QString romanizedWords;
    QString translatedWords;
    bool oppositeAligned = false;
    bool instrumental = false;
    QList<LyricSyllable> syllables;
    QList<LyricVocalGroup> backgroundVocals;
};

/// spotify's color-lyrics (SpotifyLyrics.swift), local .lrc files, or
/// Spicy Lyrics payloads
struct Lyrics {
    enum class SyncKind { Unsynced, Line, Syllable };

    QString language;
    QString provider;
    bool synchronized = false;
    SyncKind syncKind = SyncKind::Unsynced;
    bool hasRomanized = false;
    bool hasTranslations = false;
    QStringList songWriters;
    QList<LyricLine> lines;

    static std::optional<Lyrics> fromJson(const QByteArray &json);
    /// Spicy Lyrics v1 JSON payload (Syllable, Line, or Static)
    static std::optional<Lyrics> fromSpicyJson(const QByteArray &json);
    /// an .lrc file's lines: "[01:02.50]words", timed when they carry times
    static std::optional<Lyrics> fromLrc(const QString &text);
    /// the .lrc kept beside a music file, with the same name
    static std::optional<Lyrics> besideFile(const QString &musicPath);
    /// the line playing at `positionMs`, by binary search. -1 before the first
    /// line, and always for unsynchronised lyrics.
    int lineIndex(quint32 positionMs) const;
};

class LyricsModel : public QAbstractListModel {
    Q_OBJECT
    QML_ELEMENT
    QML_UNCREATABLE("Lyrics come from the player.")

    Q_PROPERTY(int count READ count NOTIFY countChanged FINAL)

public:
    enum Role {
        WordsRole = Qt::UserRole + 1,
        StartTimeMsRole,
        EndTimeMsRole,
        RomanizedWordsRole,
        TranslatedWordsRole,
        OppositeAlignedRole,
        InstrumentalRole,
        WordGroupsRole,
        BackgroundVocalsRole,
    };

    explicit LyricsModel(QObject *parent = nullptr);

    int rowCount(const QModelIndex &parent = {}) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    int count() const { return int(m_lines.size()); }
    void setLines(const QList<LyricLine> &lines);
    quint32 startTimeMs(int row) const { return row >= 0 && row < m_lines.size() ? m_lines.at(row).startTimeMs : 0; }

signals:
    void countChanged();

private:
    QList<LyricLine> m_lines;
};

} // namespace swiftify
