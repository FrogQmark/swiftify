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

#include "playback/SpicyLyricsClient.h"

#include "app/Paths.h"

#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRegularExpression>
#include <QSaveFile>
#include <QSet>
#include <QUrl>
#include <QUrlQuery>
#include <QCoroNetworkReply>

#include <memory>

namespace swiftify {

namespace {

const QString kApiBase = QStringLiteral("https://api.spicylyrics.org/v1/lyrics/");
const QString kTranslateBase = QStringLiteral("https://translate.googleapis.com/translate_a/single");
const QString kMyMemoryBase = QStringLiteral("https://api.mymemory.translated.net/get");
const QByteArray kBrowserUserAgent =
    QByteArrayLiteral("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/126.0.0.0 Safari/537.36");
constexpr qsizetype kGoogleBatchMaxLines = 35;
constexpr qsizetype kGoogleBatchMaxChars = 1'800;
constexpr qsizetype kMyMemoryMaxEncodedBytes = 380;
constexpr qint64 kCooldownMs = 5LL * 60 * 1000;

QStringList chunkByBudget(const QStringList &lines, qsizetype offset, qsizetype maxLines, qsizetype maxChars)
{
    QStringList batch;
    qsizetype chars = 0;
    for (qsizetype i = offset; i < lines.size() && batch.size() < maxLines; ++i) {
        const qsizetype add = lines.at(i).size() + 2;
        if (!batch.isEmpty() && chars + add > maxChars) {
            break;
        }
        batch.append(lines.at(i));
        chars += add;
    }
    return batch;
}

QString detectSourceLanguage(const Lyrics &lyrics, const QString &targetLanguage)
{
    const QString declared = lyrics.language.trimmed().toLower();
    if (declared.size() >= 2 && declared.left(2) != targetLanguage.left(2).toLower()) {
        return declared;
    }
    for (const LyricLine &line : lyrics.lines) {
        if (line.instrumental) {
            continue;
        }
        for (const char32_t cp : line.words.toUcs4()) {
            const QChar::Script script = QChar::script(cp);
            if (script == QChar::Script_Hangul) return QStringLiteral("ko");
            if (script == QChar::Script_Hiragana || script == QChar::Script_Katakana) return QStringLiteral("ja");
            if (script == QChar::Script_Han) return QStringLiteral("zh-CN");
            if (script == QChar::Script_Cyrillic) return QStringLiteral("ru");
            if (script == QChar::Script_Greek) return QStringLiteral("el");
            if (script == QChar::Script_Arabic) return QStringLiteral("ar");
            if (script == QChar::Script_Hebrew) return QStringLiteral("he");
            if (script == QChar::Script_Thai) return QStringLiteral("th");
            if (script == QChar::Script_Devanagari) return QStringLiteral("hi");
        }
    }
    return targetLanguage.left(2).compare(QLatin1StringView("en"), Qt::CaseInsensitive) != 0
        ? QStringLiteral("en")
        : QString();
}

// Offline phonetic transliteration for Hangul, Hiragana/Katakana, Cyrillic, and Greek.
QString transliterateKana(const QString &kana)
{
    static const QHash<QString, QString> digraphs = {
        {QStringLiteral("きゃ"), QStringLiteral("kya")}, {QStringLiteral("きゅ"), QStringLiteral("kyu")}, {QStringLiteral("きょ"), QStringLiteral("kyo")},
        {QStringLiteral("しゃ"), QStringLiteral("sha")}, {QStringLiteral("しゅ"), QStringLiteral("shu")}, {QStringLiteral("しょ"), QStringLiteral("sho")},
        {QStringLiteral("ちゃ"), QStringLiteral("cha")}, {QStringLiteral("ちゅ"), QStringLiteral("chu")}, {QStringLiteral("ちょ"), QStringLiteral("cho")},
        {QStringLiteral("にゃ"), QStringLiteral("nya")}, {QStringLiteral("にゅ"), QStringLiteral("nyu")}, {QStringLiteral("にょ"), QStringLiteral("nyo")},
        {QStringLiteral("ひゃ"), QStringLiteral("hya")}, {QStringLiteral("ひゅ"), QStringLiteral("hyu")}, {QStringLiteral("ひょ"), QStringLiteral("hyo")},
        {QStringLiteral("みゃ"), QStringLiteral("mya")}, {QStringLiteral("みゅ"), QStringLiteral("myu")}, {QStringLiteral("みょ"), QStringLiteral("myo")},
        {QStringLiteral("りゃ"), QStringLiteral("rya")}, {QStringLiteral("りゅ"), QStringLiteral("ryu")}, {QStringLiteral("りょ"), QStringLiteral("ryo")},
        {QStringLiteral("ぎゃ"), QStringLiteral("gya")}, {QStringLiteral("ぎゅ"), QStringLiteral("gyu")}, {QStringLiteral("ぎょ"), QStringLiteral("gyo")},
        {QStringLiteral("じゃ"), QStringLiteral("ja")},  {QStringLiteral("じゅ"), QStringLiteral("ju")},  {QStringLiteral("じょ"), QStringLiteral("jo")},
        {QStringLiteral("びゃ"), QStringLiteral("bya")}, {QStringLiteral("びゅ"), QStringLiteral("byu")}, {QStringLiteral("びょ"), QStringLiteral("byo")},
        {QStringLiteral("ぴゃ"), QStringLiteral("pya")}, {QStringLiteral("ぴゅ"), QStringLiteral("pyu")}, {QStringLiteral("ぴょ"), QStringLiteral("pyo")},
        {QStringLiteral("ふぁ"), QStringLiteral("fa")},  {QStringLiteral("ふぃ"), QStringLiteral("fi")},  {QStringLiteral("ふぇ"), QStringLiteral("fe")},  {QStringLiteral("ふぉ"), QStringLiteral("fo")},
        {QStringLiteral("てぃ"), QStringLiteral("ti")},  {QStringLiteral("でぃ"), QStringLiteral("di")},  {QStringLiteral("うぃ"), QStringLiteral("wi")},  {QStringLiteral("うぇ"), QStringLiteral("we")},
    };
    static const QHash<QChar, QString> singles = {
        {u'あ', QStringLiteral("a")},  {u'い', QStringLiteral("i")},   {u'う', QStringLiteral("u")},  {u'え', QStringLiteral("e")},  {u'お', QStringLiteral("o")},
        {u'か', QStringLiteral("ka")}, {u'き', QStringLiteral("ki")},  {u'く', QStringLiteral("ku")}, {u'け', QStringLiteral("ke")}, {u'こ', QStringLiteral("ko")},
        {u'さ', QStringLiteral("sa")}, {u'し', QStringLiteral("shi")}, {u'す', QStringLiteral("su")}, {u'せ', QStringLiteral("se")}, {u'そ', QStringLiteral("so")},
        {u'た', QStringLiteral("ta")}, {u'ち', QStringLiteral("chi")}, {u'つ', QStringLiteral("tsu")},{u'て', QStringLiteral("te")}, {u'と', QStringLiteral("to")},
        {u'な', QStringLiteral("na")}, {u'に', QStringLiteral("ni")},  {u'ぬ', QStringLiteral("nu")}, {u'ね', QStringLiteral("ne")}, {u'の', QStringLiteral("no")},
        {u'は', QStringLiteral("ha")}, {u'ひ', QStringLiteral("hi")},  {u'ふ', QStringLiteral("fu")}, {u'へ', QStringLiteral("he")}, {u'ほ', QStringLiteral("ho")},
        {u'ま', QStringLiteral("ma")}, {u'み', QStringLiteral("mi")},  {u'む', QStringLiteral("mu")}, {u'め', QStringLiteral("me")}, {u'も', QStringLiteral("mo")},
        {u'や', QStringLiteral("ya")}, {u'ゆ', QStringLiteral("yu")},  {u'よ', QStringLiteral("yo")},
        {u'ら', QStringLiteral("ra")}, {u'り', QStringLiteral("ri")},  {u'る', QStringLiteral("ru")}, {u'れ', QStringLiteral("re")}, {u'ろ', QStringLiteral("ro")},
        {u'わ', QStringLiteral("wa")}, {u'を', QStringLiteral("o")},   {u'ん', QStringLiteral("n")},
        {u'が', QStringLiteral("ga")}, {u'ぎ', QStringLiteral("gi")},  {u'ぐ', QStringLiteral("gu")}, {u'げ', QStringLiteral("ge")}, {u'ご', QStringLiteral("go")},
        {u'ざ', QStringLiteral("za")}, {u'じ', QStringLiteral("ji")},  {u'ず', QStringLiteral("zu")}, {u'ぜ', QStringLiteral("ze")}, {u'ぞ', QStringLiteral("zo")},
        {u'だ', QStringLiteral("da")}, {u'ぢ', QStringLiteral("ji")},  {u'づ', QStringLiteral("zu")}, {u'で', QStringLiteral("de")}, {u'ど', QStringLiteral("do")},
        {u'ば', QStringLiteral("ba")}, {u'び', QStringLiteral("bi")},  {u'ぶ', QStringLiteral("bu")}, {u'べ', QStringLiteral("be")}, {u'ぼ', QStringLiteral("bo")},
        {u'ぱ', QStringLiteral("pa")}, {u'ぴ', QStringLiteral("pi")},  {u'ぷ', QStringLiteral("pu")}, {u'ぺ', QStringLiteral("pe")}, {u'ぽ', QStringLiteral("po")},
        {u'ぁ', QStringLiteral("a")},  {u'ぃ', QStringLiteral("i")},   {u'ぅ', QStringLiteral("u")},  {u'ぇ', QStringLiteral("e")},  {u'ぉ', QStringLiteral("o")},
        {u'ゃ', QStringLiteral("ya")}, {u'ゅ', QStringLiteral("yu")},  {u'ょ', QStringLiteral("yo")}, {u'ゔ', QStringLiteral("vu")},
    };

    // Normalize Katakana (0x30A1..0x30F6) to Hiragana (0x3041..0x3096).
    QString norm;
    norm.reserve(kana.size());
    for (const QChar c : kana) {
        const ushort u = c.unicode();
        if (u >= 0x30A1 && u <= 0x30F6) {
            norm.append(QChar(u - 0x60));
        } else {
            norm.append(c);
        }
    }

    QString out;
    bool doubleNext = false;
    for (qsizetype i = 0; i < norm.size(); ++i) {
        const QChar c = norm.at(i);
        if (c == u'っ') {
            doubleNext = true;
            continue;
        }
        if (c == u'ー') {
            if (!out.isEmpty()) {
                const QChar last = out.at(out.size() - 1);
                if (QStringLiteral("aiueo").contains(last)) {
                    out.append(last);
                }
            }
            continue;
        }
        QString rom;
        if (i + 1 < norm.size()) {
            const QString pair = norm.mid(i, 2);
            if (digraphs.contains(pair)) {
                rom = digraphs.value(pair);
                ++i;
            }
        }
        if (rom.isEmpty()) {
            rom = singles.value(c);
        }
        if (!rom.isEmpty()) {
            if (doubleNext && !QStringLiteral("aiueon").contains(rom.at(0))) {
                out.append(rom.startsWith(QLatin1StringView("ch")) ? u't' : rom.at(0));
            }
            doubleNext = false;
            out.append(rom);
        } else {
            doubleNext = false;
            out.append(c);
        }
    }
    return out;
}

QString transliterateCyrillicOrGreek(QChar c)
{
    static const QHash<QChar, QString> table = {
        {u'а', QStringLiteral("a")},   {u'б', QStringLiteral("b")},   {u'в', QStringLiteral("v")},  {u'г', QStringLiteral("g")},
        {u'д', QStringLiteral("d")},   {u'е', QStringLiteral("e")},   {u'ё', QStringLiteral("yo")}, {u'ж', QStringLiteral("zh")},
        {u'з', QStringLiteral("z")},   {u'и', QStringLiteral("i")},   {u'й', QStringLiteral("y")},  {u'к', QStringLiteral("k")},
        {u'л', QStringLiteral("l")},   {u'м', QStringLiteral("m")},   {u'н', QStringLiteral("n")},  {u'о', QStringLiteral("o")},
        {u'п', QStringLiteral("p")},   {u'р', QStringLiteral("r")},   {u'с', QStringLiteral("s")},  {u'т', QStringLiteral("t")},
        {u'у', QStringLiteral("u")},   {u'ф', QStringLiteral("f")},   {u'х', QStringLiteral("kh")}, {u'ц', QStringLiteral("ts")},
        {u'ч', QStringLiteral("ch")},  {u'ш', QStringLiteral("sh")},  {u'щ', QStringLiteral("shch")},{u'ъ', QString()},
        {u'ы', QStringLiteral("y")},   {u'ь', QString()},             {u'э', QStringLiteral("e")},  {u'ю', QStringLiteral("yu")},
        {u'я', QStringLiteral("ya")},  {u'і', QStringLiteral("i")},   {u'ї', QStringLiteral("yi")}, {u'є', QStringLiteral("ye")},
        {u'ґ', QStringLiteral("g")},
        {u'α', QStringLiteral("a")},   {u'β', QStringLiteral("v")},   {u'γ', QStringLiteral("g")},  {u'δ', QStringLiteral("d")},
        {u'ε', QStringLiteral("e")},   {u'ζ', QStringLiteral("z")},   {u'η', QStringLiteral("i")},  {u'θ', QStringLiteral("th")},
        {u'ι', QStringLiteral("i")},   {u'κ', QStringLiteral("k")},   {u'λ', QStringLiteral("l")},  {u'μ', QStringLiteral("m")},
        {u'ν', QStringLiteral("n")},   {u'ξ', QStringLiteral("x")},   {u'ο', QStringLiteral("o")},  {u'π', QStringLiteral("p")},
        {u'ρ', QStringLiteral("r")},   {u'σ', QStringLiteral("s")},   {u'ς', QStringLiteral("s")},  {u'τ', QStringLiteral("t")},
        {u'υ', QStringLiteral("y")},   {u'φ', QStringLiteral("f")},   {u'χ', QStringLiteral("ch")}, {u'ψ', QStringLiteral("ps")},
        {u'ω', QStringLiteral("o")},
    };
    const QChar lower = c.toLower();
    if (!table.contains(lower)) {
        return {};
    }
    QString r = table.value(lower);
    if (c.isUpper() && !r.isEmpty()) {
        r[0] = r[0].toUpper();
    }
    return r;
}

QString normalizeLine(const QString &text)
{
    QString out = text;
    out.replace(u'\r', u' ').replace(u'\n', u' ');
    return out.trimmed();
}

QString sanitizeCacheKey(const QString &cacheKey, const QString &suffix)
{
    if (SpicyLyricsCache::isValidTrackId(cacheKey)) {
        return cacheKey + u'_' + suffix;
    }
    const QByteArray digest = QCryptographicHash::hash(cacheKey.toUtf8(), QCryptographicHash::Sha256).toHex();
    return QString::fromLatin1(digest.left(24)) + u'_' + suffix;
}

void collectUniqueLines(const Lyrics &lyrics, QStringList &out)
{
    QSet<QString> seen;
    const auto add = [&](const QString &raw) {
        const QString clean = normalizeLine(raw);
        if (!clean.isEmpty() && !seen.contains(clean)) {
            seen.insert(clean);
            out.append(clean);
        }
    };
    for (const LyricLine &line : lyrics.lines) {
        if (!line.instrumental) {
            add(line.words);
            for (const LyricVocalGroup &bg : line.backgroundVocals) {
                add(bg.words);
            }
        }
    }
}

void readEnrichCache(const QString &path, QHash<QString, QString> &translations,
                     QHash<QString, QString> &romanizations)
{
    QFile file(path);
    if (!file.exists() || file.size() > 2 * 1024 * 1024 || !file.open(QIODevice::ReadOnly)) {
        return;
    }
    const QJsonDocument doc = QJsonDocument::fromJson(file.readAll());
    file.close();
    if (!doc.isObject()) {
        QFile::remove(path);
        return;
    }
    const QJsonObject root = doc.object();
    const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
    const qint64 cachedAtMs = qint64(root.value(QStringLiteral("cachedAtMs")).toDouble());
    if (cachedAtMs <= 0 || cachedAtMs > nowMs + 60'000 || nowMs - cachedAtMs >= SpicyLyricsCache::kMaxCacheAgeMs) {
        QFile::remove(path);
        return;
    }
    const auto loadMap = [](const QJsonObject &obj, QHash<QString, QString> &target, bool filterRomanized) {
        for (auto it = obj.constBegin(); it != obj.constEnd(); ++it) {
            if (!it.value().isString()) {
                continue;
            }
            const QString val = it.value().toString();
            if (filterRomanized) {
                // Drop earlier metadata-polluted entries without discarding valid cached lines.
                if (!SpicyLyricsClient::containsNonLatinLetters(it.key())
                    || val.compare(QLatin1StringView("enen"), Qt::CaseInsensitive) == 0) {
                    continue;
                }
            }
            target.insert(it.key(), val);
        }
    };
    loadMap(root.value(QStringLiteral("translations")).toObject(), translations, false);
    loadMap(root.value(QStringLiteral("romanizations")).toObject(), romanizations, true);
}

void writeEnrichCache(const QString &path, const QHash<QString, QString> &translations,
                      const QHash<QString, QString> &romanizations)
{
    QDir().mkpath(QFileInfo(path).absolutePath());
    const auto saveMap = [](const QHash<QString, QString> &source) {
        QJsonObject obj;
        for (auto it = source.constBegin(); it != source.constEnd(); ++it) {
            obj.insert(it.key(), it.value());
        }
        return obj;
    };
    QJsonObject root;
    root.insert(QStringLiteral("cacheVersion"), 2);
    root.insert(QStringLiteral("cachedAtMs"), double(QDateTime::currentMSecsSinceEpoch()));
    root.insert(QStringLiteral("translations"), saveMap(translations));
    root.insert(QStringLiteral("romanizations"), saveMap(romanizations));

    QSaveFile file(path);
    if (file.open(QIODevice::WriteOnly)) {
        file.write(QJsonDocument(root).toJson(QJsonDocument::Compact));
        file.commit();
    }
}

void applyEnrichmentToLyrics(Lyrics &lyrics, bool applyRomanized, bool applyTranslated,
                           const QHash<QString, QString> &translations,
                           const QHash<QString, QString> &romanizations)
{
    for (LyricLine &line : lyrics.lines) {
        if (line.instrumental) {
            continue;
        }
        const QString clean = normalizeLine(line.words);
        if (applyRomanized && line.romanizedWords.isEmpty() && SpicyLyricsClient::containsNonLatinLetters(line.words)) {
            const QString rom = romanizations.value(clean);
            if (!rom.isEmpty() && rom.compare(line.words, Qt::CaseInsensitive) != 0) {
                line.romanizedWords = rom;
                lyrics.hasRomanized = true;
            }
        }
        if (applyTranslated) {
            const QString trans = translations.value(clean);
            if (!trans.isEmpty() && trans.compare(line.words, Qt::CaseInsensitive) != 0) {
                line.translatedWords = trans;
                lyrics.hasTranslations = true;
            } else if (!line.translatedWords.isEmpty()) {
                lyrics.hasTranslations = true;
            }
        }
        for (LyricVocalGroup &bg : line.backgroundVocals) {
            const QString bgClean = normalizeLine(bg.words);
            if (applyRomanized && bg.romanizedWords.isEmpty() && SpicyLyricsClient::containsNonLatinLetters(bg.words)) {
                const QString rom = romanizations.value(bgClean);
                if (!rom.isEmpty() && rom.compare(bg.words, Qt::CaseInsensitive) != 0) {
                    bg.romanizedWords = rom;
                    lyrics.hasRomanized = true;
                }
            }
            if (applyTranslated) {
                const QString trans = translations.value(bgClean);
                if (!trans.isEmpty() && trans.compare(bg.words, Qt::CaseInsensitive) != 0) {
                    bg.translatedWords = trans;
                    lyrics.hasTranslations = true;
                } else if (!bg.translatedWords.isEmpty()) {
                    lyrics.hasTranslations = true;
                }
            }
        }
    }
}

bool payloadHasContent(const QJsonObject &root)
{
    if (root.contains(QStringLiteral("Content"))) {
        return true;
    }
    const QJsonValue body = root.value(QStringLiteral("Body"));
    return body.isObject() && body.toObject().contains(QStringLiteral("Content"));
}

QStringList splitNonEmptyLines(const QString &text)
{
    if (text.isEmpty()) {
        return {};
    }
    return text.split(u'\n', Qt::SkipEmptyParts);
}

QString buildEnrichCachePath(const SpicyLyricsCache &cache, const QString &cacheKey,
                             bool fetchRomanized, bool needTranslated, const QString &cleanLang)
{
    QString cacheSuffix = needTranslated ? cleanLang : QStringLiteral("rom");
    if (fetchRomanized && needTranslated) {
        cacheSuffix += QStringLiteral("_rom");
    }
    return cache.directory() + QStringLiteral("/translations/")
        + sanitizeCacheKey(cacheKey, cacheSuffix) + QStringLiteral(".json");
}

bool enrichPlans(const Lyrics &lyrics, bool wantRomanized, bool wantTranslated, const QString &targetLanguage,
                 bool &fetchRomanizedOut, bool &needTranslatedOut, QString &cleanLangOut, QStringList &allLinesOut)
{
    const bool needRomanized = wantRomanized && !lyrics.hasRomanized;
    cleanLangOut = wantTranslated ? targetLanguage.trimmed() : QString();
    needTranslatedOut = wantTranslated && !cleanLangOut.isEmpty();
    if (!needRomanized && !needTranslatedOut) {
        fetchRomanizedOut = false;
        return false;
    }

    collectUniqueLines(lyrics, allLinesOut);
    if (allLinesOut.isEmpty()) {
        fetchRomanizedOut = false;
        return false;
    }

    bool anyNonLatin = false;
    if (needRomanized) {
        for (const QString &line : allLinesOut) {
            if (SpicyLyricsClient::containsNonLatinLetters(line)) {
                anyNonLatin = true;
                break;
            }
        }
    }
    fetchRomanizedOut = needRomanized && anyNonLatin;
    return fetchRomanizedOut || needTranslatedOut;
}

} // namespace

SpicyLyricsCache::SpicyLyricsCache(QString directory)
    : m_directory(directory.isEmpty() ? paths::cacheDirectory() + QStringLiteral("/spicy_lyrics") : std::move(directory))
{
}

bool SpicyLyricsCache::isValidTrackId(const QString &trackId)
{
    static const QRegularExpression pattern(QStringLiteral("^[A-Za-z0-9]{22}$"));
    return pattern.match(trackId).hasMatch();
}

QString SpicyLyricsCache::filePath(const QString &trackId) const
{
    return m_directory + u'/' + trackId + QStringLiteral(".json");
}

SpicyLyricsCache::EntryState SpicyLyricsCache::inspectEntry(const QString &trackId, qint64 nowMs,
                                                            QByteArray *payloadOut) const
{
    if (!isValidTrackId(trackId)) {
        return EntryState::Missing;
    }
    const QString path = filePath(trackId);
    QFile file(path);
    if (!file.exists()) {
        return EntryState::Missing;
    }
    if (file.size() > 4 * 1024 * 1024 || !file.open(QIODevice::ReadOnly)) {
        QFile::remove(path);
        return EntryState::Missing;
    }
    QJsonParseError error;
    const QJsonDocument doc = QJsonDocument::fromJson(file.readAll(), &error);
    file.close();
    if (error.error != QJsonParseError::NoError || !doc.isObject()) {
        QFile::remove(path);
        return EntryState::Missing;
    }
    const QJsonObject wrapper = doc.object();
    const QJsonValue cachedAtVal = wrapper.value(QStringLiteral("cachedAtMs"));
    const QJsonValue payloadVal = wrapper.value(QStringLiteral("payload"));
    if (!cachedAtVal.isDouble() || !payloadVal.isObject()) {
        QFile::remove(path);
        return EntryState::Missing;
    }
    const qint64 cachedAtMs = qint64(cachedAtVal.toDouble());
    // reject entries older than 30 days (or absurdly far in the future)
    if (cachedAtMs > nowMs + 60'000 || nowMs - cachedAtMs >= kMaxCacheAgeMs) {
        QFile::remove(path);
        return EntryState::Expired;
    }
    if (payloadOut) {
        *payloadOut = QJsonDocument(payloadVal.toObject()).toJson(QJsonDocument::Compact);
    }
    return EntryState::Fresh;
}

std::optional<QByteArray> SpicyLyricsCache::readIfFresh(const QString &trackId, qint64 nowMs) const
{
    QByteArray payload;
    if (inspectEntry(trackId, nowMs, &payload) == EntryState::Fresh) {
        return payload;
    }
    return std::nullopt;
}

bool SpicyLyricsCache::isFresh(const QString &trackId, qint64 nowMs) const
{
    return inspectEntry(trackId, nowMs) == EntryState::Fresh;
}

bool SpicyLyricsCache::write(const QString &trackId, const QByteArray &payloadJson, qint64 nowMs) const
{
    if (!isValidTrackId(trackId)) {
        return false;
    }
    QJsonParseError error;
    const QJsonDocument payloadDoc = QJsonDocument::fromJson(payloadJson, &error);
    if (error.error != QJsonParseError::NoError || !payloadDoc.isObject()) {
        return false;
    }
    QDir().mkpath(m_directory);
    QJsonObject wrapper;
    wrapper.insert(QStringLiteral("cachedAtMs"), double(nowMs));
    wrapper.insert(QStringLiteral("payload"), payloadDoc.object());

    QSaveFile file(filePath(trackId));
    if (!file.open(QIODevice::WriteOnly)) {
        return false;
    }
    file.write(QJsonDocument(wrapper).toJson(QJsonDocument::Compact));
    return file.commit();
}

QStringList SpicyLyricsCache::staleTrackIds(const QStringList &trackIds, qint64 nowMs) const
{
    QStringList stale;
    for (const QString &trackId : trackIds) {
        if (isValidTrackId(trackId) && inspectEntry(trackId, nowMs) != EntryState::Fresh) {
            stale.append(trackId);
        }
    }
    return stale;
}

bool SpicyLyricsCache::hasExpiredTrack(const QStringList &trackIds, qint64 nowMs) const
{
    for (const QString &trackId : trackIds) {
        if (inspectEntry(trackId, nowMs) == EntryState::Expired) {
            return true;
        }
    }
    return false;
}

int SpicyLyricsCache::purgeExpired(qint64 nowMs) const
{
    const QDir dir(m_directory);
    if (!dir.exists()) {
        return 0;
    }
    int removed = 0;
    const QFileInfoList entries = dir.entryInfoList({QStringLiteral("*.json")}, QDir::Files);
    for (const QFileInfo &info : entries) {
        if (inspectEntry(info.completeBaseName(), nowMs) == EntryState::Expired) {
            ++removed;
        }
    }
    return removed;
}

SpicyLyricsClient::SpicyLyricsClient(QNetworkAccessManager *network, QString cacheDirectory)
    : m_network(network)
    , m_cache(std::move(cacheDirectory))
{
}

QCoro::Task<std::optional<QByteArray>> SpicyLyricsClient::fetchLyricsJson(QString trackId, QString apiKey,
                                                                          bool bypassCache)
{
    const QString cleanKey = apiKey.trimmed();
    if (!SpicyLyricsCache::isValidTrackId(trackId) || cleanKey.isEmpty()) {
        co_return std::nullopt;
    }
    if (!bypassCache) {
        if (const auto cached = m_cache.readIfFresh(trackId)) {
            co_return cached;
        }
    }
    if (!m_network) {
        co_return std::nullopt;
    }

    QNetworkRequest request(QUrl(kApiBase + trackId));
    request.setTransferTimeout(10'000);
    request.setRawHeader("Authorization", QByteArray("Bearer ") + cleanKey.toUtf8());
    request.setRawHeader("Accept", "application/json");

    std::unique_ptr<QNetworkReply> reply(m_network->get(request));
    co_await qCoro(reply.get()).waitForFinished();

    const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    if (reply->error() != QNetworkReply::NoError || status == 0 || status < 200 || status >= 300) {
        co_return std::nullopt;
    }
    const QByteArray payload = reply->readAll();
    QJsonParseError parseError;
    const QJsonDocument doc = QJsonDocument::fromJson(payload, &parseError);
    if (parseError.error != QJsonParseError::NoError || !doc.isObject() || !payloadHasContent(doc.object())) {
        co_return std::nullopt;
    }
    m_cache.write(trackId, payload);
    co_return payload;
}

bool SpicyLyricsClient::containsNonLatinLetters(const QString &text)
{
    for (const char32_t cp : text.toUcs4()) {
        if (QChar::isLetter(cp)) {
            const QChar::Script script = QChar::script(cp);
            if (script != QChar::Script_Latin && script != QChar::Script_Common && script != QChar::Script_Inherited) {
                return true;
            }
        }
    }
    return false;
}

QString SpicyLyricsClient::romanizeOffline(const QString &text)
{
    if (!containsNonLatinLetters(text)) {
        return {};
    }
    static constexpr const char *kHangulInitial[] = {
        "g", "kk", "n", "d", "tt", "r", "m", "b", "pp", "s", "ss", "", "j", "jj", "ch", "k", "t", "p", "h"
    };
    static constexpr const char *kHangulMedial[] = {
        "a", "ae", "ya", "yae", "eo", "e", "yeo", "ye", "o", "wa", "wae", "oe", "yo",
        "u", "wo", "we", "wi", "yu", "eu", "ui", "i"
    };
    static constexpr const char *kHangulFinal[] = {
        "", "k", "k", "k", "n", "n", "n", "t", "l", "k", "m", "l", "l", "l", "l", "l",
        "m", "p", "p", "t", "t", "ng", "t", "t", "k", "t", "p", "h"
    };

    QString out;
    QString kanaBuf;
    bool hadHanOrComplex = false;
    bool convertedAny = false;
    const auto flushKana = [&] {
        if (!kanaBuf.isEmpty()) {
            out.append(transliterateKana(kanaBuf));
            kanaBuf.clear();
            convertedAny = true;
        }
    };

    for (const QChar c : text) {
        const ushort u = c.unicode();
        const QChar::Script script = QChar::script(u);
        if (script == QChar::Script_Hiragana || script == QChar::Script_Katakana || c == u'ー') {
            kanaBuf.append(c);
            continue;
        }
        flushKana();
        if (u >= 0xAC00 && u <= 0xD7A3) {
            const int sIdx = u - 0xAC00;
            const int l = sIdx / 588;
            const int v = (sIdx % 588) / 28;
            const int t = sIdx % 28;
            out.append(QLatin1StringView(kHangulInitial[l]));
            out.append(QLatin1StringView(kHangulMedial[v]));
            out.append(QLatin1StringView(kHangulFinal[t]));
            convertedAny = true;
        } else if (script == QChar::Script_Cyrillic || script == QChar::Script_Greek) {
            const QString t = transliterateCyrillicOrGreek(c);
            out.append(t.isEmpty() ? QString(c) : t);
            convertedAny = true;
        } else if (script != QChar::Script_Latin && script != QChar::Script_Common
                   && script != QChar::Script_Inherited && c.isLetter()) {
            hadHanOrComplex = true;
            out.append(c);
        } else {
            out.append(c);
        }
    }
    flushKana();
    // Only return a whole-line offline romanization when no un-romanizable Han/complex letters remain.
    if (hadHanOrComplex || !convertedAny) {
        return {};
    }
    return out.trimmed();
}

QString SpicyLyricsClient::parseMyMemoryResponse(const QByteArray &json)
{
    QJsonParseError error;
    const QJsonDocument doc = QJsonDocument::fromJson(json, &error);
    if (error.error != QJsonParseError::NoError || !doc.isObject()) {
        return {};
    }
    const QJsonObject root = doc.object();
    if (root.value(QStringLiteral("quotaFinished")).toBool(false)) {
        return {};
    }
    const int status = root.value(QStringLiteral("responseStatus")).toInt(200);
    if (status != 200) {
        return {};
    }
    return root.value(QStringLiteral("responseData")).toObject().value(QStringLiteral("translatedText")).toString();
}

bool SpicyLyricsClient::parseTranslateResponse(const QByteArray &json, QString *translatedOut, QString *romanizedOut)
{
    QJsonParseError error;
    const QJsonDocument doc = QJsonDocument::fromJson(json, &error);
    if (error.error != QJsonParseError::NoError || !doc.isArray()) {
        return false;
    }
    const QJsonArray root = doc.array();
    if (root.isEmpty() || !root.at(0).isArray()) {
        return false;
    }

    QString translated;
    QString romanized;
    const QJsonArray blocks = root.at(0).toArray();
    for (const QJsonValue &entryVal : blocks) {
        if (!entryVal.isArray()) {
            continue;
        }
        const QJsonArray seg = entryVal.toArray();
        if (!seg.isEmpty() && seg.at(0).isString()) {
            translated += seg.at(0).toString();
        } else if (seg.size() >= 4 && seg.at(0).isNull()) {
            const QString srcRom = seg.at(3).toString();
            if (!srcRom.isEmpty()) {
                romanized += srcRom;
            }
        }
    }

    if (translatedOut) {
        *translatedOut = translated;
    }
    if (romanizedOut) {
        *romanizedOut = romanized;
    }
    return !translated.isEmpty() || !romanized.isEmpty();
}

bool SpicyLyricsClient::applyCachedEnrichment(Lyrics &lyrics, const QString &cacheKey,
                                              bool wantRomanized, bool wantTranslated,
                                              const QString &targetLanguage) const
{
    bool fetchRomanized = false;
    bool needTranslated = false;
    QString cleanLang;
    QStringList allLines;
    if (!enrichPlans(lyrics, wantRomanized, wantTranslated, targetLanguage,
                     fetchRomanized, needTranslated, cleanLang, allLines)) {
        return false;
    }

    const QString cacheFile = buildEnrichCachePath(m_cache, cacheKey, fetchRomanized, needTranslated, cleanLang);
    QHash<QString, QString> translations;
    QHash<QString, QString> romanizations;
    readEnrichCache(cacheFile, translations, romanizations);

    if (fetchRomanized) {
        for (const QString &line : allLines) {
            if (!romanizations.contains(line)) {
                const QString off = romanizeOffline(line);
                if (!off.isEmpty()) {
                    romanizations.insert(line, off);
                }
            }
        }
    }
    applyEnrichmentToLyrics(lyrics, fetchRomanized, needTranslated, translations, romanizations);

    for (const QString &line : allLines) {
        const bool missTrans = needTranslated && !translations.contains(line);
        const bool missRom = fetchRomanized && containsNonLatinLetters(line) && !romanizations.contains(line);
        if (missTrans || missRom) {
            return true;
        }
    }
    return false;
}

QCoro::Task<std::pair<QStringList, QStringList>> SpicyLyricsClient::requestGoogleBatch(
    QStringList batch, QString targetLang, bool includeRomanized)
{
    if (!m_network || batch.isEmpty() || QDateTime::currentMSecsSinceEpoch() < m_googleCooldownUntilMs) {
        co_return std::pair<QStringList, QStringList>{};
    }
    QUrl url(kTranslateBase);
    QUrlQuery query;
    query.addQueryItem(QStringLiteral("client"), QStringLiteral("gtx"));
    query.addQueryItem(QStringLiteral("sl"), QStringLiteral("auto"));
    query.addQueryItem(QStringLiteral("tl"), targetLang);
    query.addQueryItem(QStringLiteral("dt"), QStringLiteral("t"));
    if (includeRomanized) {
        query.addQueryItem(QStringLiteral("dt"), QStringLiteral("rm"));
    }
    url.setQuery(query);

    QNetworkRequest request(url);
    request.setTransferTimeout(6'000);
    request.setHeader(QNetworkRequest::ContentTypeHeader,
                      QStringLiteral("application/x-www-form-urlencoded; charset=UTF-8"));
    request.setRawHeader("User-Agent", kBrowserUserAgent);
    request.setRawHeader("Accept", "application/json");

    // Separate lines by paragraph breaks (\n\n) so Google preserves 1-to-1 line alignment.
    const QByteArray body = QByteArray("q=") + QUrl::toPercentEncoding(batch.join(QStringLiteral("\n\n")));
    std::unique_ptr<QNetworkReply> reply(m_network->post(request, body));
    co_await qCoro(reply.get()).waitForFinished();

    const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    if (status == 429 || status == 403) {
        m_googleCooldownUntilMs = QDateTime::currentMSecsSinceEpoch() + kCooldownMs;
        co_return std::pair<QStringList, QStringList>{};
    }
    if (reply->error() != QNetworkReply::NoError || status == 0 || status < 200 || status >= 300) {
        co_return std::pair<QStringList, QStringList>{};
    }
    QString translatedText;
    QString romanizedText;
    if (!parseTranslateResponse(reply->readAll(), &translatedText, &romanizedText)) {
        co_return std::pair<QStringList, QStringList>{};
    }
    co_return std::pair<QStringList, QStringList>{
        splitNonEmptyLines(translatedText),
        splitNonEmptyLines(romanizedText)
    };
}

QCoro::Task<QStringList> SpicyLyricsClient::requestMyMemoryBatch(
    QStringList batch, QString sourceLang, QString targetLang)
{
    if (!m_network || batch.isEmpty() || sourceLang.isEmpty()
        || sourceLang.left(2).compare(targetLang.left(2), Qt::CaseInsensitive) == 0
        || QDateTime::currentMSecsSinceEpoch() < m_myMemoryCooldownUntilMs) {
        co_return QStringList{};
    }
    QUrl url(kMyMemoryBase);
    QUrlQuery query;
    query.addQueryItem(QStringLiteral("q"), batch.join(u'\n'));
    query.addQueryItem(QStringLiteral("langpair"), sourceLang + u'|' + targetLang);
    url.setQuery(query);

    QNetworkRequest request(url);
    request.setTransferTimeout(6'000);
    request.setRawHeader("User-Agent", kBrowserUserAgent);
    request.setRawHeader("Accept", "application/json");

    std::unique_ptr<QNetworkReply> reply(m_network->get(request));
    co_await qCoro(reply.get()).waitForFinished();

    const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    if (status == 429 || status == 403) {
        m_myMemoryCooldownUntilMs = QDateTime::currentMSecsSinceEpoch() + kCooldownMs;
        co_return QStringList{};
    }
    if (reply->error() != QNetworkReply::NoError || status == 0 || status < 200 || status >= 300) {
        co_return QStringList{};
    }
    const QString translatedText = parseMyMemoryResponse(reply->readAll());
    if (translatedText.isEmpty()) {
        co_return QStringList{};
    }
    co_return splitNonEmptyLines(translatedText);
}

QCoro::Task<bool> SpicyLyricsClient::enrichLyrics(Lyrics &lyrics, QString cacheKey,
                                                  bool wantRomanized, bool wantTranslated, QString targetLanguage)
{
    bool fetchRomanized = false;
    bool needTranslated = false;
    QString cleanLang;
    QStringList allLines;
    if (!enrichPlans(lyrics, wantRomanized, wantTranslated, targetLanguage,
                     fetchRomanized, needTranslated, cleanLang, allLines)) {
        co_return false;
    }

    const QString cacheFile = buildEnrichCachePath(m_cache, cacheKey, fetchRomanized, needTranslated, cleanLang);
    QHash<QString, QString> translations;
    QHash<QString, QString> romanizations;
    readEnrichCache(cacheFile, translations, romanizations);

    bool updated = false;
    if (fetchRomanized) {
        for (const QString &line : allLines) {
            if (!romanizations.contains(line)) {
                const QString off = romanizeOffline(line);
                if (!off.isEmpty()) {
                    romanizations.insert(line, off);
                    updated = true;
                }
            }
        }
    }

    QStringList missingLatin;
    QStringList missingNonLatin;
    for (const QString &line : allLines) {
        const bool nonLatin = containsNonLatinLetters(line);
        const bool missTrans = needTranslated && !translations.contains(line);
        const bool missRom = fetchRomanized && nonLatin && !romanizations.contains(line);
        if (missTrans || missRom) {
            if (nonLatin) {
                missingNonLatin.append(line);
            } else {
                missingLatin.append(line);
            }
        }
    }

    const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
    if (m_network && nowMs >= m_googleCooldownUntilMs && (!missingLatin.isEmpty() || !missingNonLatin.isEmpty())) {
        const QString googleTarget = needTranslated ? cleanLang : QStringLiteral("en");
        const QList<std::pair<QStringList, bool>> passes = {
            {missingNonLatin, fetchRomanized},
            {needTranslated ? missingLatin : QStringList{}, false},
        };
        for (const auto &[list, askRom] : passes) {
            qsizetype offset = 0;
            while (offset < list.size() && QDateTime::currentMSecsSinceEpoch() >= m_googleCooldownUntilMs) {
                const QStringList batch = chunkByBudget(list, offset, kGoogleBatchMaxLines, kGoogleBatchMaxChars);
                if (batch.isEmpty()) {
                    break;
                }
                offset += batch.size();
                auto [transLines, romLines] = co_await requestGoogleBatch(batch, googleTarget, askRom);
                if (needTranslated && transLines.size() == batch.size()) {
                    for (qsizetype i = 0; i < batch.size(); ++i) {
                        translations.insert(batch.at(i), transLines.at(i).trimmed());
                        updated = true;
                    }
                }
                if (askRom && romLines.size() == batch.size()) {
                    for (qsizetype i = 0; i < batch.size(); ++i) {
                        romanizations.insert(batch.at(i), romLines.at(i).trimmed());
                        updated = true;
                    }
                }
            }
        }
    }

    // Fallback to MyMemory when Google failed or is rate-limited and translations are still missing.
    if (m_network && needTranslated && QDateTime::currentMSecsSinceEpoch() >= m_myMemoryCooldownUntilMs) {
        QStringList stillUntranslated;
        for (const QString &line : allLines) {
            if (!translations.contains(line)) {
                stillUntranslated.append(line);
            }
        }
        const QString sourceLang = detectSourceLanguage(lyrics, cleanLang);
        if (!stillUntranslated.isEmpty() && !sourceLang.isEmpty()) {
            qsizetype offset = 0;
            while (offset < stillUntranslated.size() && QDateTime::currentMSecsSinceEpoch() >= m_myMemoryCooldownUntilMs) {
                QStringList batch;
                qsizetype encodedLen = 0;
                for (; offset < stillUntranslated.size() && batch.size() < 6; ++offset) {
                    const QString &candidate = stillUntranslated.at(offset);
                    const qsizetype add = QUrl::toPercentEncoding(candidate).size() + 3;
                    if (!batch.isEmpty() && encodedLen + add > kMyMemoryMaxEncodedBytes) {
                        break;
                    }
                    batch.append(candidate);
                    encodedLen += add;
                }
                if (batch.isEmpty()) {
                    break;
                }
                const QStringList transLines = co_await requestMyMemoryBatch(batch, sourceLang, cleanLang);
                if (transLines.size() == batch.size()) {
                    for (qsizetype i = 0; i < batch.size(); ++i) {
                        translations.insert(batch.at(i), transLines.at(i).trimmed());
                        updated = true;
                    }
                } else {
                    break;
                }
            }
        }
    }

    if (updated) {
        writeEnrichCache(cacheFile, translations, romanizations);
    }

    const bool beforeRom = lyrics.hasRomanized;
    const bool beforeTrans = lyrics.hasTranslations;
    applyEnrichmentToLyrics(lyrics, fetchRomanized, needTranslated, translations, romanizations);
    co_return updated || lyrics.hasRomanized != beforeRom || lyrics.hasTranslations != beforeTrans;
}

QStringList splitNonEmptyLines(const QString &text)
{
    if (text.isEmpty()) {
        return {};
    }
    return text.split(u'\n', Qt::SkipEmptyParts);
}

QString buildEnrichCachePath(const SpicyLyricsCache &cache, const QString &cacheKey,
                             bool fetchRomanized, bool needTranslated, const QString &cleanLang)
{
    QString cacheSuffix = needTranslated ? cleanLang : QStringLiteral("rom");
    if (fetchRomanized && needTranslated) {
        cacheSuffix += QStringLiteral("_rom");
    }
    return cache.directory() + QStringLiteral("/translations/")
        + sanitizeCacheKey(cacheKey, cacheSuffix) + QStringLiteral(".json");
}

bool enrichPlans(const Lyrics &lyrics, bool wantRomanized, bool wantTranslated, const QString &targetLanguage,
                 bool &fetchRomanizedOut, bool &needTranslatedOut, QString &cleanLangOut, QStringList &allLinesOut)
{
    const bool needRomanized = wantRomanized && !lyrics.hasRomanized;
    cleanLangOut = wantTranslated ? targetLanguage.trimmed() : QString();
    needTranslatedOut = wantTranslated && !cleanLangOut.isEmpty();
    if (!needRomanized && !needTranslatedOut) {
        fetchRomanizedOut = false;
        return false;
    }

    collectUniqueLines(lyrics, allLinesOut);
    if (allLinesOut.isEmpty()) {
        fetchRomanizedOut = false;
        return false;
    }

    bool anyNonLatin = false;
    if (needRomanized) {
        for (const QString &line : allLinesOut) {
            if (SpicyLyricsClient::containsNonLatinLetters(line)) {
                anyNonLatin = true;
                break;
            }
        }
    }
    fetchRomanizedOut = needRomanized && anyNonLatin;
    return fetchRomanizedOut || needTranslatedOut;
}

} // namespace swiftify
