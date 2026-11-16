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
constexpr qsizetype kTranslateBatchSize = 12;

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
    if (root.value(QStringLiteral("cacheVersion")).toInt() != 2) {
        QFile::remove(path);
        return;
    }
    const qint64 nowMs = QDateTime::currentMSecsSinceEpoch();
    const qint64 cachedAtMs = qint64(root.value(QStringLiteral("cachedAtMs")).toDouble());
    if (cachedAtMs <= 0 || cachedAtMs > nowMs + 60'000 || nowMs - cachedAtMs >= SpicyLyricsCache::kMaxCacheAgeMs) {
        QFile::remove(path);
        return;
    }
    const auto loadMap = [](const QJsonObject &obj, QHash<QString, QString> &target) {
        for (auto it = obj.constBegin(); it != obj.constEnd(); ++it) {
            if (it.value().isString()) {
                target.insert(it.key(), it.value().toString());
            }
        }
    };
    loadMap(root.value(QStringLiteral("translations")).toObject(), translations);
    loadMap(root.value(QStringLiteral("romanizations")).toObject(), romanizations);
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

    bool updated = false;
    if ((!missingLatin.isEmpty() || !missingNonLatin.isEmpty()) && m_network) {
        bool aborted = false;
        const auto requestBatch = [&](const QStringList &batch, bool includeRomanized)
            -> QCoro::Task<std::pair<QStringList, QStringList>> {
            if (aborted || batch.isEmpty()) {
                co_return std::pair<QStringList, QStringList>{};
            }
            QUrl url(kTranslateBase);
            QUrlQuery query;
            query.addQueryItem(QStringLiteral("client"), QStringLiteral("gtx"));
            query.addQueryItem(QStringLiteral("sl"), QStringLiteral("auto"));
            query.addQueryItem(QStringLiteral("tl"), needTranslated ? cleanLang : QStringLiteral("en"));
            query.addQueryItem(QStringLiteral("dt"), QStringLiteral("t"));
            if (includeRomanized) {
                query.addQueryItem(QStringLiteral("dt"), QStringLiteral("rm"));
            }
            url.setQuery(query);

            QNetworkRequest request(url);
            request.setTransferTimeout(6'000);
            request.setHeader(QNetworkRequest::ContentTypeHeader,
                              QStringLiteral("application/x-www-form-urlencoded; charset=UTF-8"));
            request.setRawHeader("Accept", "application/json");

            const QByteArray body = QByteArray("q=") + QUrl::toPercentEncoding(batch.join(u'\n'));
            std::unique_ptr<QNetworkReply> reply(m_network->post(request, body));
            co_await qCoro(reply.get()).waitForFinished();

            const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
            if (reply->error() != QNetworkReply::NoError || status == 0 || status < 200 || status >= 300) {
                aborted = true;
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
        };

        const auto recordMatched = [&](const QStringList &batch, bool includeRomanized,
                                       const QStringList &transLines, const QStringList &romLines) {
            const bool transOk = needTranslated && transLines.size() == batch.size();
            const bool romOk = includeRomanized && romLines.size() == batch.size();
            if (!transOk && !romOk) {
                return false;
            }
            for (qsizetype i = 0; i < batch.size(); ++i) {
                if (transOk) {
                    translations.insert(batch.at(i), transLines.at(i).trimmed());
                    updated = true;
                }
                if (romOk) {
                    romanizations.insert(batch.at(i), romLines.at(i).trimmed());
                    updated = true;
                }
            }
            return (!needTranslated || transOk) && (!includeRomanized || romOk);
        };

        const auto processMissing = [&](const QStringList &list, bool includeRomanized) -> QCoro::Task<> {
            for (qsizetype offset = 0; !aborted && offset < list.size(); offset += kTranslateBatchSize) {
                const QStringList batch = list.mid(offset, kTranslateBatchSize);
                auto [transLines, romLines] = co_await requestBatch(batch, includeRomanized);
                if (aborted) {
                    break;
                }
                if (!recordMatched(batch, includeRomanized, transLines, romLines) && batch.size() > 1) {
                    // Split once into halves rather than flooding Google with per-line requests.
                    const qsizetype mid = batch.size() / 2;
                    for (const QStringList &half : {batch.mid(0, mid), batch.mid(mid)}) {
                        if (aborted) {
                            break;
                        }
                        auto [hTrans, hRom] = co_await requestBatch(half, includeRomanized);
                        recordMatched(half, includeRomanized, hTrans, hRom);
                    }
                }
            }
        };

        if (!missingNonLatin.isEmpty()) {
            co_await processMissing(missingNonLatin, fetchRomanized);
        }
        if (!missingLatin.isEmpty() && needTranslated && !aborted) {
            co_await processMissing(missingLatin, false);
        }
        if (updated) {
            writeEnrichCache(cacheFile, translations, romanizations);
        }
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
