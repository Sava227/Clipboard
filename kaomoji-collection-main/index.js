"use strict";

const data = require("./kaomoji.json");

const categories = Object.keys(data);

/**
 * Get all kaomoji in a category
 * @param {string} category - Category slug (e.g. "smile", "cat", "angry")
 * @returns {string[]} Array of kaomoji strings
 */
function list(category) {
  const key = category.toLowerCase().replace(/\s+/g, "-");
  return data[key] || [];
}

/**
 * Get a random kaomoji from a category (or from all if no category specified)
 * @param {string} [category] - Optional category slug
 * @returns {string} A random kaomoji
 */
function random(category) {
  let pool;
  if (category) {
    pool = list(category);
    if (pool.length === 0) {
      // fallback to all
      pool = Object.values(data).flat();
    }
  } else {
    pool = Object.values(data).flat();
  }
  return pool[Math.floor(Math.random() * pool.length)];
}

/**
 * Search kaomoji across all categories
 * @param {string} query - Search term (matches category names)
 * @returns {Object} Matching categories and their kaomoji
 */
function search(query) {
  const q = query.toLowerCase();
  const results = {};
  for (const [cat, kaomojis] of Object.entries(data)) {
    if (cat.includes(q)) {
      results[cat] = kaomojis;
    }
  }
  return results;
}

/**
 * Get all available categories
 * @returns {string[]} Array of category slugs
 */
function getCategories() {
  return categories.slice();
}

/**
 * Get stats about the collection
 * @returns {Object} Collection statistics
 */
function stats() {
  const total = Object.values(data).reduce((sum, arr) => sum + arr.length, 0);
  return {
    categories: categories.length,
    total,
    largest: categories.reduce((max, cat) =>
      data[cat].length > (data[max] || []).length ? cat : max, categories[0]),
  };
}

module.exports = { list, random, search, categories: getCategories, stats };
