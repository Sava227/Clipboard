#include "ClipboardHistory.hpp"

#include <algorithm>
#include <chrono>
#include <cctype>
#include <fstream>
#include <iomanip>
#include <random>
#include <sstream>

namespace {
std::string toLower(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    return value;
}

bool containsCaseInsensitive(const std::string& haystack, const std::string& needle) {
    if (needle.empty()) {
        return true;
    }
    return toLower(haystack).find(toLower(needle)) != std::string::npos;
}

std::string hexEncode(const std::string& input) {
    std::ostringstream stream;
    stream << std::hex << std::setfill('0');
    for (unsigned char ch : input) {
        stream << std::setw(2) << static_cast<int>(ch);
    }
    return stream.str();
}

std::string hexDecode(const std::string& input) {
    std::string output;
    output.reserve(input.size() / 2);

    for (std::size_t i = 0; i + 1 < input.size(); i += 2) {
        const auto byte = input.substr(i, 2);
        output.push_back(static_cast<char>(std::stoi(byte, nullptr, 16)));
    }

    return output;
}

std::vector<std::string> splitTabs(const std::string& line) {
    std::vector<std::string> parts;
    std::stringstream stream(line);
    std::string part;

    while (std::getline(stream, part, '\t')) {
        parts.push_back(part);
    }

    return parts;
}

std::string kindToStorage(ClipboardKind kind) {
    switch (kind) {
        case ClipboardKind::Text: return "text";
        case ClipboardKind::Link: return "link";
        case ClipboardKind::Image: return "image";
        case ClipboardKind::File: return "file";
    }
}

ClipboardKind kindFromStorage(const std::string& value) {
    if (value == "link") return ClipboardKind::Link;
    if (value == "image") return ClipboardKind::Image;
    if (value == "file") return ClipboardKind::File;
    return ClipboardKind::Text;
}
}

ClipboardHistory::ClipboardHistory(std::string storagePath) : storagePath_(std::move(storagePath)) {}

void ClipboardHistory::load() {
    items_.clear();

    std::ifstream file(storagePath_);
    std::string line;
    while (std::getline(file, line)) {
        auto parts = splitTabs(line);
        if (parts.size() != 10 || parts[0] != "1") {
            continue;
        }

        ClipboardItem item;
        item.id = parts[1];
        item.kind = kindFromStorage(parts[2]);
        if (item.kind == ClipboardKind::Image || item.kind == ClipboardKind::File) {
            continue;
        }
        item.title = hexDecode(parts[3]);
        item.preview = hexDecode(parts[4]);
        item.content = hexDecode(parts[5]);
        item.createdAt = std::stoll(parts[7]);
        item.pinned = parts[8] == "1";
        item.favorite = parts[9] == "1";
        items_.push_back(std::move(item));
    }
}

void ClipboardHistory::save() const {
    std::ofstream file(storagePath_, std::ios::trunc);
    for (const auto& item : items_) {
        file << "1"
             << '\t' << item.id
             << '\t' << kindToStorage(item.kind)
             << '\t' << hexEncode(item.title)
             << '\t' << hexEncode(item.preview)
             << '\t' << hexEncode(item.content)
             << '\t' << hexEncode(item.imageBase64)
             << '\t' << item.createdAt
             << '\t' << (item.pinned ? "1" : "0")
             << '\t' << (item.favorite ? "1" : "0")
             << '\n';
    }
}

void ClipboardHistory::add(ClipboardItem item) {
    items_.erase(std::remove_if(items_.begin(), items_.end(), [&](const ClipboardItem& existing) {
        return existing.kind == item.kind
            && existing.content == item.content
            && existing.imageBase64 == item.imageBase64;
    }), items_.end());

    items_.insert(items_.begin(), std::move(item));
    trimToLimit();
    save();
}

void ClipboardHistory::remove(const std::string& id) {
    items_.erase(std::remove_if(items_.begin(), items_.end(), [&](const ClipboardItem& item) {
        return item.id == id;
    }), items_.end());
    save();
}

void ClipboardHistory::updateContent(const std::string& id, const std::string& content, const std::string& title, const std::string& preview) {
    for (auto& item : items_) {
        if (item.id == id) {
            item.content = content;
            item.title = title;
            item.preview = preview;
            break;
        }
    }
    save();
}

void ClipboardHistory::togglePinned(const std::string& id) {
    for (auto& item : items_) {
        if (item.id == id) {
            item.pinned = !item.pinned;
            break;
        }
    }
    save();
}

void ClipboardHistory::toggleFavorite(const std::string& id) {
    for (auto& item : items_) {
        if (item.id == id) {
            item.favorite = !item.favorite;
            break;
        }
    }
    save();
}

void ClipboardHistory::clearUnpinned() {
    items_.erase(std::remove_if(items_.begin(), items_.end(), [](const ClipboardItem& item) {
        return !item.pinned;
    }), items_.end());
    save();
}

void ClipboardHistory::clearAll() {
    items_.clear();
    save();
}

std::vector<ClipboardItem> ClipboardHistory::filtered(const std::string& query, std::optional<ClipboardKind> kind) const {
    std::vector<ClipboardItem> result;

    for (const auto& item : items_) {
        if (kind.has_value() && item.kind != *kind) {
            continue;
        }

        if (!containsCaseInsensitive(item.title, query)
            && !containsCaseInsensitive(item.preview, query)
            && !containsCaseInsensitive(item.content, query)) {
            continue;
        }

        result.push_back(item);
    }

    std::stable_sort(result.begin(), result.end(), [](const ClipboardItem& lhs, const ClipboardItem& rhs) {
        if (lhs.favorite != rhs.favorite) return lhs.favorite > rhs.favorite;
        return lhs.createdAt > rhs.createdAt;
    });

    return result;
}

std::optional<ClipboardItem> ClipboardHistory::find(const std::string& id) const {
    auto it = std::find_if(items_.begin(), items_.end(), [&](const ClipboardItem& item) {
        return item.id == id;
    });
    if (it == items_.end()) {
        return std::nullopt;
    }
    return *it;
}

const std::vector<ClipboardItem>& ClipboardHistory::all() const {
    return items_;
}

void ClipboardHistory::trimToLimit() {
    std::size_t unpinnedCount = 0;

    items_.erase(std::remove_if(items_.begin(), items_.end(), [&](const ClipboardItem& item) {
        if (item.pinned) return false;
        unpinnedCount++;
        return unpinnedCount > maxUnpinnedItems;
    }), items_.end());
}

std::string clipboardKindName(ClipboardKind kind) {
    switch (kind) {
        case ClipboardKind::Text: return "Text";
        case ClipboardKind::Link: return "Link";
        case ClipboardKind::Image: return "Image";
        case ClipboardKind::File: return "File";
    }
}

std::string clipboardKindIconName(ClipboardKind kind) {
    switch (kind) {
        case ClipboardKind::Text: return "text.alignleft";
        case ClipboardKind::Link: return "link";
        case ClipboardKind::Image: return "photo";
        case ClipboardKind::File: return "doc";
    }
}

std::string makeClipboardID() {
    static std::random_device device;
    static std::mt19937_64 generator(device());
    static std::uniform_int_distribution<std::uint64_t> distribution;

    std::ostringstream stream;
    stream << std::hex << distribution(generator) << distribution(generator);
    return stream.str();
}

std::int64_t currentUnixTime() {
    const auto now = std::chrono::system_clock::now();
    return std::chrono::duration_cast<std::chrono::seconds>(now.time_since_epoch()).count();
}
