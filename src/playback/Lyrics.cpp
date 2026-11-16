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

#include "playback/Lyrics.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QVariantList>
#include <QVariantMap>

#include <algorithm>
#include <cmath>

namespace swiftify {

namespace {

constexpr quint32 kInstrumentalGapThresholdMs = 5'000;

quint32 secondsToMs(const QJsonValue &value)
{
    if (!value.isDouble()) {
        return 0;
    }
    const double seconds = value.toDouble();
    if (!std::isfinite(seconds) || seconds <= 0.0) {
        return 0;
    }
    return quint32(std::llround(seconds * 1000.0));
}

QString firstString(const QJsonObject &object, std::initializer_list<const char *> keys)
{
    for (const char *key : keys) {
        const QString value = object.value(QLatin1StringView(key)).toString();
        if (!value.isEmpty()) {
            return value;
        }
    }
    return {};
}

QString joinSyllableText(const QList<LyricSyllable> &syllables, bool romanized)
{
    QString out;
    for (qsizetype index = 0; index < syllables.size(); ++index) {
        const LyricSyllable &syllable = syllables.at(index);
        const QString &piece = romanized ? syllable.romanizedText : syllable.text;
        if (piece.isEmpty()) {
            continue;
        }
        out += piece;
        if (!syllable.isPartOfWord && index + 1 < syllables.size() && !piece.endsWith(u' ')) {
            const QString &next = romanized ? syllables.at(index + 1).romanizedText : syllables.at(index + 1).text;
            if (!next.isEmpty() && !next.startsWith(u' ')) {
                out += u' ';
            }
        }
    }
    return out.trimmed();
}

LyricVocalGroup parseVocalGroup(const QJsonObject &object)
{
    LyricVocalGroup group;
    group.startTimeMs = secondsToMs(object.value(QStringLiteral("StartTime")));
    group.endTimeMs = secondsToMs(object.value(QStringLiteral("EndTime")));

    const QJsonArray syllablesArray = object.value(QStringLiteral("Syllables")).toArray();
    for (const QJsonValue &value : syllablesArray) {
        if (!value.isObject()) {
            continue;
        }
        const QJsonObject s = value.toObject();
        LyricSyllable syllable;
        syllable.startTimeMs = secondsToMs(s.value(QStringLiteral("StartTime")));
        syllable.endTimeMs = secondsToMs(s.value(QStringLiteral("EndTime")));
        syllable.text = s.value(QStringLiteral("Text")).toString();
        syllable.romanizedText = firstString(s, {"TransliteratedText", "RomanizedText"});
        syllable.isPartOfWord = s.value(QStringLiteral("IsPartOfWord")).toBool(false);
        if (syllable.endTimeMs < syllable.startTimeMs) {
            syllable.endTimeMs = syllable.startTimeMs;
        }
        group.syllables.append(std::move(syllable));
    }

    if (!group.syllables.isEmpty()) {
        if (group.startTimeMs == 0) {
            group.startTimeMs = group.syllables.first().startTimeMs;
        }
        if (group.endTimeMs <= group.startTimeMs) {
            group.endTimeMs = group.syllables.last().endTimeMs;
        }
        group.words = joinSyllableText(group.syllables, false);
        group.romanizedWords = joinSyllableText(group.syllables, true);
    } else {
        group.words = object.value(QStringLiteral("Text")).toString().trimmed();
        group.romanizedWords = firstString(object, {"TransliteratedText", "RomanizedText"}).trimmed();
    }
    return group;
}

QVariantList buildWordGroups(const QList<LyricSyllable> &syllables)
{
    QVariantList words;
    if (syllables.isEmpty()) {
        return words;
    }

    QVariantList currentWord;
    for (qsizetype index = 0; index < syllables.size(); ++index) {
        const LyricSyllable &syllable = syllables.at(index);
        if (syllable.text.isEmpty()) {
            continue;
        }
        // Trim leading/trailing spaces on individual chunks when grouping into
        // words because QML Flow handles inter-word spacing cleanly.
        const QString clean = syllable.text.trimmed();
        if (clean.isEmpty()) {
            if (!currentWord.isEmpty()) {
                words.append(QVariant::fromValue(currentWord));
                currentWord.clear();
            }
            continue;
        }
        QVariantMap map;
        map.insert(QStringLiteral("text"), clean);
        map.insert(QStringLiteral("startTimeMs"), int(syllable.startTimeMs));
        map.insert(QStringLiteral("endTimeMs"), int(syllable.endTimeMs));
        currentWord.append(map);

        const bool endsWord = !syllable.isPartOfWord || syllable.text.endsWith(u' ');
        if (endsWord) {
            words.append(QVariant::fromValue(currentWord));
            currentWord.clear();
        }
    }
    if (!currentWord.isEmpty()) {
        words.append(QVariant::fromValue(currentWord));
    }
    return words;
}

} // namespace

std::optional<Lyrics> Lyrics::fromLrc(const QString &text)
{
    // [mm:ss], [mm:ss.xx] or [mm:ss.xxx], one or more ahead of the words
    static const QRegularExpression stamp(QStringLiteral(R"(^\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\])"));
    // [ar:...], [ti:...] and the like say who and what, and are not sung
    static const QRegularExpression tag(QStringLiteral(R"(^\[[a-zA-Z#]+:.*\]\s*$)"));

    Lyrics lyrics;
    lyrics.provider = QStringLiteral("LRC file");
    QList<LyricLine> timed;
    QList<LyricLine> plain;
    for (QString line : text.split(u'\n')) {
        line = line.trimmed();
        QList<quint32> starts;
        for (auto match = stamp.match(line); match.hasMatch(); match = stamp.match(line)) {
            const QString fraction = match.captured(3);
            const quint32 milliseconds = fraction.isEmpty() ? 0
                : quint32(fraction.toUInt() * (fraction.size() == 1 ? 100 : fraction.size() == 2 ? 10 : 1));
            starts.append(quint32(match.captured(1).toUInt() * 60'000 + match.captured(2).toUInt() * 1000) + milliseconds);
            line = line.mid(match.capturedLength()).trimmed();
        }
        if (!starts.isEmpty()) {
            for (const quint32 start : starts) {
                timed.append({start, 0, line});
            }
        } else if (!line.isEmpty() && !tag.match(line).hasMatch()) {
            plain.append({0, 0, line});
        }
    }
    if (!timed.isEmpty()) {
        std::stable_sort(timed.begin(), timed.end(),
                         [](const LyricLine &a, const LyricLine &b) { return a.startTimeMs < b.startTimeMs; });
        for (qsizetype index = 0; index + 1 < timed.size(); ++index) {
            timed[index].endTimeMs = timed[index + 1].startTimeMs;
        }
        timed.last().endTimeMs = timed.last().startTimeMs + 5000;
        lyrics.synchronized = true;
        lyrics.syncKind = SyncKind::Line;
        lyrics.lines = timed;
    } else {
        lyrics.lines = plain;
    }
    if (lyrics.lines.isEmpty()) {
        return std::nullopt;
    }
    return lyrics;
}

std::optional<Lyrics> Lyrics::besideFile(const QString &musicPath)
{
    const QFileInfo music(musicPath);
    // "song.mp3" goes with "song.lrc". named outright rather than matched by
    // a pattern: a name like "Injury [HQ]" is a pattern of its own
    for (const char *suffix : {".lrc", ".LRC", ".Lrc"}) {
        QFile file(music.dir().filePath(music.completeBaseName() + QLatin1StringView(suffix)));
        if (file.exists() && file.size() < 512 * 1024 && file.open(QIODevice::ReadOnly)) {
            return fromLrc(QString::fromUtf8(file.readAll()));
        }
    }
    return std::nullopt;
}

std::optional<Lyrics> Lyrics::fromJson(const QByteArray &json)
{
    QJsonParseError error;
    const QJsonObject object = QJsonDocument::fromJson(json, &error).object();
    if (error.error != QJsonParseError::NoError || !object.contains(QStringLiteral("lines"))) {
        return std::nullopt;
    }
    Lyrics lyrics;
    lyrics.language = object.value(QStringLiteral("language")).toString();
    lyrics.provider = object.value(QStringLiteral("provider")).toString();
    lyrics.synchronized = object.value(QStringLiteral("syncType")).toString() == QLatin1StringView("lineSynced");
    lyrics.syncKind = lyrics.synchronized ? SyncKind::Line : SyncKind::Unsynced;
    for (const QJsonValue &value : object.value(QStringLiteral("lines")).toArray()) {
        const QJsonObject line = value.toObject();
        lyrics.lines.append({
            quint32(line.value(QStringLiteral("startTimeMs")).toDouble()),
            quint32(line.value(QStringLiteral("endTimeMs")).toDouble()),
            line.value(QStringLiteral("words")).toString(),
        });
    }
    // spotify gives synced lines no end, so each lasts until the next one
    // starts and the last for a few seconds
    for (qsizetype index = 0; index < lyrics.lines.size(); ++index) {
        LyricLine &line = lyrics.lines[index];
        if (line.endTimeMs <= line.startTimeMs) {
            line.endTimeMs = index + 1 < lyrics.lines.size() ? lyrics.lines.at(index + 1).startTimeMs
                                                             : line.startTimeMs + 5000;
        }
    }
    return lyrics;
}

std::optional<Lyrics> Lyrics::fromSpicyJson(const QByteArray &json)
{
    QJsonParseError error;
    const QJsonDocument doc = QJsonDocument::fromJson(json, &error);
    if (error.error != QJsonParseError::NoError || !doc.isObject()) {
        return std::nullopt;
    }
    const QJsonObject root = doc.object();
    const QJsonObject body = root.value(QStringLiteral("Body")).isObject()
        ? root.value(QStringLiteral("Body")).toObject()
        : root;

    if (!body.value(QStringLiteral("Content")).isArray()) {
        return std::nullopt;
    }

    Lyrics lyrics;
    lyrics.provider = QStringLiteral("Spicy Lyrics");
    const QString type = body.value(QStringLiteral("Type")).toString();
    if (type == QLatin1StringView("Syllable")) {
        lyrics.synchronized = true;
        lyrics.syncKind = SyncKind::Syllable;
    } else if (type == QLatin1StringView("Line")) {
        lyrics.synchronized = true;
        lyrics.syncKind = SyncKind::Line;
    } else {
        lyrics.synchronized = false;
        lyrics.syncKind = SyncKind::Unsynced;
    }

    for (const QJsonValue &writer : body.value(QStringLiteral("SongWriters")).toArray()) {
        const QString name = writer.toString().trimmed();
        if (!name.isEmpty()) {
            lyrics.songWriters.append(name);
        }
    }

    QList<LyricLine> parsed;
    for (const QJsonValue &entryValue : body.value(QStringLiteral("Content")).toArray()) {
        if (!entryValue.isObject()) {
            continue;
        }
        const QJsonObject entry = entryValue.toObject();
        const QString entryType = entry.value(QStringLiteral("Type")).toString();
        if (entryType == QLatin1StringView("Instrumental")) {
            const quint32 start = secondsToMs(entry.value(QStringLiteral("StartTime")));
            const quint32 end = secondsToMs(entry.value(QStringLiteral("EndTime")));
            if (end > start) {
                LyricLine line;
                line.startTimeMs = start;
                line.endTimeMs = end;
                line.instrumental = true;
                parsed.append(std::move(line));
            }
            continue;
        }

        LyricLine line;
        line.oppositeAligned = entry.value(QStringLiteral("OppositeAligned")).toBool(false);
        if (entry.value(QStringLiteral("Lead")).isObject()) {
            const LyricVocalGroup lead = parseVocalGroup(entry.value(QStringLiteral("Lead")).toObject());
            line.startTimeMs = lead.startTimeMs;
            line.endTimeMs = lead.endTimeMs;
            line.words = lead.words;
            line.romanizedWords = lead.romanizedWords;
            line.syllables = lead.syllables;
        } else {
            const LyricVocalGroup lead = parseVocalGroup(entry);
            line.startTimeMs = lead.startTimeMs;
            line.endTimeMs = lead.endTimeMs;
            line.words = lead.words;
            line.romanizedWords = lead.romanizedWords;
            line.syllables = lead.syllables;
        }

        for (const QJsonValue &bgValue : entry.value(QStringLiteral("Background")).toArray()) {
            if (!bgValue.isObject()) {
                continue;
            }
            LyricVocalGroup bg = parseVocalGroup(bgValue.toObject());
            if (!bg.words.isEmpty()) {
                if (!bg.romanizedWords.isEmpty()) {
                    lyrics.hasRomanized = true;
                }
                line.backgroundVocals.append(std::move(bg));
            }
        }

        if (!line.romanizedWords.isEmpty()) {
            lyrics.hasRomanized = true;
        }
        if (!line.words.isEmpty() || !line.backgroundVocals.isEmpty()) {
            parsed.append(std::move(line));
        }
    }

    if (parsed.isEmpty()) {
        return std::nullopt;
    }

    if (lyrics.synchronized) {
        std::stable_sort(parsed.begin(), parsed.end(),
                         [](const LyricLine &a, const LyricLine &b) { return a.startTimeMs < b.startTimeMs; });
        for (qsizetype index = 0; index < parsed.size(); ++index) {
            LyricLine &line = parsed[index];
            if (line.endTimeMs <= line.startTimeMs) {
                line.endTimeMs = index + 1 < parsed.size() ? parsed.at(index + 1).startTimeMs
                                                           : line.startTimeMs + 5000;
            }
        }
        // Insert instrumental break indicators for long silent stretches that
        // don't already have an explicit Instrumental block.
        QList<LyricLine> withBreaks;
        if (!parsed.first().instrumental && parsed.first().startTimeMs >= kInstrumentalGapThresholdMs) {
            LyricLine intro;
            intro.startTimeMs = 0;
            intro.endTimeMs = parsed.first().startTimeMs;
            intro.instrumental = true;
            withBreaks.append(std::move(intro));
        }
        for (qsizetype index = 0; index < parsed.size(); ++index) {
            withBreaks.append(parsed.at(index));
            if (index + 1 < parsed.size() && !parsed.at(index).instrumental && !parsed.at(index + 1).instrumental) {
                const quint32 gapStart = parsed.at(index).endTimeMs;
                const quint32 gapEnd = parsed.at(index + 1).startTimeMs;
                if (gapEnd > gapStart && gapEnd - gapStart >= kInstrumentalGapThresholdMs) {
                    LyricLine gap;
                    gap.startTimeMs = gapStart;
                    gap.endTimeMs = gapEnd;
                    gap.instrumental = true;
                    withBreaks.append(std::move(gap));
                }
            }
        }
        lyrics.lines = std::move(withBreaks);
    } else {
        lyrics.lines = std::move(parsed);
    }

    return lyrics;
}

int Lyrics::lineIndex(quint32 positionMs) const
{
    if (!synchronized || lines.isEmpty()) {
        return -1;
    }
    qsizetype lower = 0;
    qsizetype upper = lines.size();
    while (lower < upper) {
        const qsizetype middle = lower + (upper - lower) / 2;
        if (lines.at(middle).startTimeMs <= positionMs) {
            lower = middle + 1;
        } else {
            upper = middle;
        }
    }
    return int(lower) - 1;
}

LyricsModel::LyricsModel(QObject *parent)
    : QAbstractListModel(parent)
{
}

int LyricsModel::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : int(m_lines.size());
}

QVariant LyricsModel::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() >= m_lines.size()) {
        return {};
    }
    const LyricLine &line = m_lines.at(index.row());
    switch (role) {
    case WordsRole: return line.words;
    case StartTimeMsRole: return line.startTimeMs;
    case EndTimeMsRole: return line.endTimeMs;
    case RomanizedWordsRole: return line.romanizedWords;
    case OppositeAlignedRole: return line.oppositeAligned;
    case InstrumentalRole: return line.instrumental;
    case WordGroupsRole: return buildWordGroups(line.syllables);
    case BackgroundVocalsRole: {
        QVariantList list;
        for (const LyricVocalGroup &bg : line.backgroundVocals) {
            QVariantMap entry;
            entry.insert(QStringLiteral("words"), bg.words);
            entry.insert(QStringLiteral("romanizedWords"), bg.romanizedWords);
            entry.insert(QStringLiteral("startTimeMs"), int(bg.startTimeMs));
            entry.insert(QStringLiteral("endTimeMs"), int(bg.endTimeMs));
            entry.insert(QStringLiteral("wordGroups"), buildWordGroups(bg.syllables));
            list.append(entry);
        }
        return list;
    }
    default: return {};
    }
}

QHash<int, QByteArray> LyricsModel::roleNames() const
{
    return {
        {WordsRole, "words"},
        {StartTimeMsRole, "startTimeMs"},
        {EndTimeMsRole, "endTimeMs"},
        {RomanizedWordsRole, "romanizedWords"},
        {OppositeAlignedRole, "oppositeAligned"},
        {InstrumentalRole, "instrumental"},
        {WordGroupsRole, "wordGroups"},
        {BackgroundVocalsRole, "backgroundVocals"},
    };
}

void LyricsModel::setLines(const QList<LyricLine> &lines)
{
    beginResetModel();
    m_lines = lines;
    endResetModel();
    emit countChanged();
}

} // namespace swiftify
