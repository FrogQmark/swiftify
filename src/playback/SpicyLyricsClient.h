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

#include "playback/Lyrics.h"

#include <QByteArray>
#include <QCoroTask>
#include <QDateTime>
#include <QString>
#include <QStringList>

#include <optional>
#include <utility>

class QNetworkAccessManager;

namespace swiftify {

/// on-disk cache for Spicy Lyrics payloads, bounded to 30 days per Spicy
/// Lyrics' terms of service. designed so single-track playback and future
/// playlist bulk downloads share the same freshness checks and invalidation.
class SpicyLyricsCache {
public:
    static constexpr qint64 kMaxCacheAgeMs = 30LL * 24 * 60 * 60 * 1000;

    explicit SpicyLyricsCache(QString directory = {});

    const QString &directory() const { return m_directory; }
    static bool isValidTrackId(const QString &trackId);
    QString filePath(const QString &trackId) const;

    std::optional<QByteArray> readIfFresh(const QString &trackId,
                                          qint64 nowMs = QDateTime::currentMSecsSinceEpoch()) const;
    bool isFresh(const QString &trackId, qint64 nowMs = QDateTime::currentMSecsSinceEpoch()) const;
    bool write(const QString &trackId, const QByteArray &payloadJson,
               qint64 nowMs = QDateTime::currentMSecsSinceEpoch()) const;

    /// tracks from `trackIds` whose cached lyrics are missing or >= 30 days old
    QStringList staleTrackIds(const QStringList &trackIds,
                              qint64 nowMs = QDateTime::currentMSecsSinceEpoch()) const;
    /// true when at least one track in `trackIds` had cached lyrics that
    /// reached the 30-day limit (so a downloaded playlist can refresh all of them)
    bool hasExpiredTrack(const QStringList &trackIds,
                         qint64 nowMs = QDateTime::currentMSecsSinceEpoch()) const;
    int purgeExpired(qint64 nowMs = QDateTime::currentMSecsSinceEpoch()) const;

private:
    enum class EntryState { Missing, Fresh, Expired };

    EntryState inspectEntry(const QString &trackId, qint64 nowMs, QByteArray *payloadOut = nullptr) const;

    QString m_directory;
};

/// fetches word/syllable-synced lyrics from the public Spicy Lyrics API using
/// the user's own client key and caches responses on disk for up to 30 days.
class SpicyLyricsClient {
public:
    /// client keys allow 600 requests/min; bulk playlist queues pace below
    /// that so normal playback is never throttled.
    static constexpr int kBulkRateLimitPerMinute = 500;
    static constexpr int kBulkMinIntervalMs = 60'000 / kBulkRateLimitPerMinute;

    explicit SpicyLyricsClient(QNetworkAccessManager *network, QString cacheDirectory = {});

    SpicyLyricsCache &cache() { return m_cache; }
    const SpicyLyricsCache &cache() const { return m_cache; }

    QCoro::Task<std::optional<QByteArray>> fetchLyricsJson(QString trackId, QString apiKey,
                                                           bool bypassCache = false);

    /// applies cached romanization/translation if present on disk without I/O wait;
    /// returns true when uncached lines still need network enrichment.
    bool applyCachedEnrichment(Lyrics &lyrics, const QString &cacheKey,
                               bool wantRomanized, bool wantTranslated, const QString &targetLanguage) const;

    /// optionally fills missing romanized and/or translated lines using cached
    /// results or public translation requests, bounded to the 30-day cache TTL.
    /// returns true when `lyrics` was updated with new entries.
    QCoro::Task<bool> enrichLyrics(Lyrics &lyrics, QString cacheKey,
                                     bool wantRomanized, bool wantTranslated, QString targetLanguage);

    static bool containsNonLatinLetters(const QString &text);
    static QString romanizeOffline(const QString &text);
    static bool parseTranslateResponse(const QByteArray &json, QString *translatedOut, QString *romanizedOut);
    static QString parseMyMemoryResponse(const QByteArray &json);

private:
    QCoro::Task<std::pair<QStringList, QStringList>> requestGoogleBatch(QStringList batch, QString targetLang,
                                                                        bool includeRomanized);
    QCoro::Task<QStringList> requestMyMemoryBatch(QStringList batch, QString sourceLang, QString targetLang);

    QNetworkAccessManager *m_network;
    SpicyLyricsCache m_cache;
    qint64 m_googleCooldownUntilMs = 0;
    qint64 m_myMemoryCooldownUntilMs = 0;
};

} // namespace swiftify
