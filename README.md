# Unread MCP Server

A read-only Model Context Protocol (MCP) server for searching your Unread RSS reader database. This server provides keyword-based fulltext search capabilities for articles stored in the Unread app.

## Features

- **Keyword-based fulltext search** - NOT semantic/vector search
- Search across article titles, content, authors, and feed names
- Filter by article status (starred, read, unread)
- Search within specific feeds
- Database statistics
- Boolean operators (AND, OR, NOT)
- Exact phrase search with quotes

## Installation

1. Ensure you have the Unread app installed and have articles in your database
2. Clone or copy this directory to `~/Developer/unread-mcp/`
3. Make the script executable:
   ```bash
   chmod +x ~/Developer/unread-mcp/unread-mcp.sh
   ```

## Configuration

Add the following to your Claude Desktop configuration file:

**macOS**: `~/Library/Application Support/Claude/claude_desktop_config.json`

```json
{
  "mcpServers": {
    "unread-search": {
      "command": "/Users/YOUR_USERNAME/Developer/unread-mcp/unread-mcp.sh"
    }
  }
}
```

Replace `YOUR_USERNAME` with your actual username.

## Usage

Once configured, you can use the following tools in Claude:

### search-articles
Search through all articles using keywords:
- Simple keywords: `bicycle`, `javascript`
- Boolean operators: `AI OR artificial intelligence`, `python NOT django`
- Exact phrases: `"climate change"`
- Use `*` or empty query to get most recently read articles
- Filter by status: starred, read, unread
- Returns brief preview (~300 chars) and article ID

### get-article
Retrieve the full text content of a specific article:
- Use the article ID from search results
- Returns complete article content with metadata

### get-stats
Get database statistics including total articles, unread count, starred count

### list-feeds
List all RSS feeds with article counts

### search-by-feed
Search articles within a specific feed
- Returns brief preview and article ID

## Examples

- "Search my starred articles for AI or artificial intelligence"
- "Find unread articles about cycling"
- "Show me articles about javascript but not react"
- "Search for 'climate change' in my articles"
- "List my top feeds"
- "Search The Radavist feed for bike articles"

## Important Notes

- This is a **read-only** server - it cannot modify your database
- Search is **keyword-based**, not semantic - use specific terms
- The database path is hardcoded to the default Unread location
- Requires `sqlite3` and `jq` to be installed (standard on macOS)

## Troubleshooting

Check the `requests.log` file in the same directory as the script for debugging information.

## Dependencies

- bash
- sqlite3
- jq
- Unread app with articles in the database