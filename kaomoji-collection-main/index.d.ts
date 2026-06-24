/**
 * Get all kaomoji in a category
 * @param category - Category slug (e.g. "smile", "cat", "angry")
 * @returns Array of kaomoji strings
 */
export function list(category: string): string[];

/**
 * Get a random kaomoji from a category (or from all if no category specified)
 * @param category - Optional category slug
 * @returns A random kaomoji
 */
export function random(category?: string): string;

/**
 * Search kaomoji across all categories
 * @param query - Search term (matches category names)
 * @returns Matching categories and their kaomoji
 */
export function search(query: string): Record<string, string[]>;

/**
 * Get all available categories
 * @returns Array of category slugs
 */
export function categories(): string[];

/**
 * Get stats about the collection
 * @returns Collection statistics
 */
export function stats(): {
  categories: number;
  total: number;
  largest: string;
};
