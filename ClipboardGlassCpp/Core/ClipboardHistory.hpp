#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

enum class ClipboardKind {
    Text,
    Link,
    Image,
    File
};

struct ClipboardItem {
    std::string id;
    ClipboardKind kind = ClipboardKind::Text;
    std::string title;
    std::string preview;
    std::string content;
    std::string imageBase64;
    std::int64_t createdAt = 0;
    bool pinned = false;
    bool favorite = false;
};

class ClipboardHistory {
public:
    explicit ClipboardHistory(std::string storagePath);

    void load();
    void save() const;

    void add(ClipboardItem item);
    void remove(const std::string& id);
    void updateContent(const std::string& id, const std::string& content, const std::string& title, const std::string& preview);
    void togglePinned(const std::string& id);
    void toggleFavorite(const std::string& id);
    void clearUnpinned();
    void clearAll();

    std::vector<ClipboardItem> filtered(const std::string& query, std::optional<ClipboardKind> kind) const;
    std::optional<ClipboardItem> find(const std::string& id) const;

    const std::vector<ClipboardItem>& all() const;
    std::size_t maxUnpinnedItems = 120;

private:
    std::string storagePath_;
    std::vector<ClipboardItem> items_;

    void trimToLimit();
};

std::string clipboardKindName(ClipboardKind kind);
std::string clipboardKindIconName(ClipboardKind kind);
std::string makeClipboardID();
std::int64_t currentUnixTime();
