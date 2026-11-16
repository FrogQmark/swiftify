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

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QRegularExpression>
#include <QSaveFile>
#include <QUrl>
#include <QCoroNetworkReply>

#include <memory>

namespace swiftify {

namespace {

const QString kApiBase = QStringLiteral("https://api.spicylyrics.org/v1/lyrics/");

bool payloadHasContent(const QJsonObject &root)
{
    if (root.contains(QStringLiteral("Content"))) {
        return true;
    }
    const QJsonValue body = root.value(QStringLiteral("Body"));
    return body.isObject() && body.toObject().contains(QStringLiteral("Content"));
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
    if (status < 200 || status >= 300) {
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

} // namespace swiftify
