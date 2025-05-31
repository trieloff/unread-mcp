#!/bin/bash

# Unread MCP Server - Read-only search interface for Unread RSS reader database
# Configuration
DB_PATH="/Users/trieloff/Library/Containers/com.goldenhillsoftware.Unread2/Data/Documents/Databases/database_39B1B45D-57D2-4D34-87D9-304217A52C0F.db"
LOG_DIR="$(dirname "$(realpath "$0")")"
LOG_FILE="$LOG_DIR/requests.log"

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

# Empty log file and add startup message
echo "Starting unread-mcp.sh at $(date)" > "$LOG_FILE"

# Helper function to create JSON responses
create_json_response() {
  local id="$1"
  local content="$2"
  local response=$(jq -cn --arg id "$id" --arg content "$content" '{jsonrpc: "2.0", id: ($id | tonumber), result: $content | fromjson}')
  echo "<< $response" >> "$LOG_FILE"
  echo "$response"
}

# Helper function to create error responses
create_error_response() {
  local id="$1"
  local code="$2"
  local message="$3"
  local response=$(jq -cn --arg id "$id" --arg code "$code" --arg message "$message" \
    '{jsonrpc: "2.0", id: ($id | tonumber), error: {code: ($code | tonumber), message: $message}}')
  echo "<< $response" >> "$LOG_FILE"
  echo "$response"
}

# Check if database exists
if [ ! -f "$DB_PATH" ]; then
  echo "ERROR: Unread database not found at $DB_PATH" >> "$LOG_FILE"
  exit 1
fi

# Process incoming requests
while read -r line; do
  # Log the request
  echo ">> $line" >> "$LOG_FILE"

  # Parse JSON input using jq
  if ! method=$(echo "$line" | jq -r '.method // empty' 2>/dev/null); then
    echo "Failed to parse JSON input" >> "$LOG_FILE"
    continue
  fi

  id=$(echo "$line" | jq -r '.id // empty' 2>/dev/null)
  
  case "$method" in
    "initialize")
      response=$(jq -cn --arg id "$id" '{
        jsonrpc: "2.0",
        id: ($id | tonumber),
        result: {
          protocolVersion: "2024-11-05",
          capabilities: {
            experimental: {},
            prompts: { listChanged: false },
            resources: { subscribe: false, listChanged: false },
            tools: { listChanged: false }
          },
          serverInfo: {
            name: "unread-search",
            version: "1.0.0"
          }
        }
      }')
      echo "<< $response" >> "$LOG_FILE"
      echo "$response"
      ;;
      
    "notifications/initialized")
      # Do nothing
      ;;
      
    "tools/list")
      response=$(jq -cn --arg id "$id" '{
        jsonrpc: "2.0",
        id: ($id | tonumber),
        result: {
          tools: [
            {
              name: "search-articles",
              description: "Search through articles in your Unread RSS reader database using keyword-based fulltext search. This is NOT a semantic/vector search - use specific keywords, boolean operators (AND, OR, NOT), and exact phrases in quotes. The search covers article titles, content, authors, and feed names.",
              inputSchema: {
                type: "object",
                properties: {
                  query: { 
                    title: "Search Query", 
                    type: "string",
                    description: "Keyword search query. Supports: simple keywords (bicycle, javascript), boolean operators (AI OR artificial intelligence, python NOT django), exact phrases (\"climate change\"), and combinations. Searches across title, content, author, and feed name." 
                  },
                  filter: {
                    title: "Filter",
                    type: "string",
                    enum: ["all", "starred", "unread", "read"],
                    default: "all",
                    description: "Filter articles by status"
                  },
                  limit: {
                    title: "Limit",
                    type: "integer",
                    minimum: 1,
                    maximum: 100,
                    default: 20,
                    description: "Maximum number of results to return"
                  },
                  include_content: {
                    title: "Include Content",
                    type: "boolean",
                    default: false,
                    description: "Include article content preview in results (first 500 chars)"
                  }
                },
                required: ["query"]
              }
            },
            {
              name: "get-stats",
              description: "Get statistics about the Unread database including total articles, unread count, starred count, and feed information",
              inputSchema: {
                type: "object",
                properties: {}
              }
            },
            {
              name: "list-feeds",
              description: "List all RSS feeds in the database with article counts",
              inputSchema: {
                type: "object",
                properties: {
                  limit: {
                    title: "Limit",
                    type: "integer",
                    minimum: 1,
                    maximum: 100,
                    default: 30,
                    description: "Maximum number of feeds to return"
                  }
                }
              }
            },
            {
              name: "search-by-feed",
              description: "Search articles within a specific feed using keyword-based fulltext search",
              inputSchema: {
                type: "object",
                properties: {
                  feed_name: {
                    title: "Feed Name",
                    type: "string",
                    description: "Exact name of the feed to search within"
                  },
                  query: {
                    title: "Search Query",
                    type: "string",
                    description: "Keyword search query within the specified feed. Supports same syntax as search-articles."
                  },
                  filter: {
                    title: "Filter",
                    type: "string",
                    enum: ["all", "starred", "unread", "read"],
                    default: "all",
                    description: "Filter articles by status"
                  },
                  limit: {
                    title: "Limit",
                    type: "integer",
                    minimum: 1,
                    maximum: 100,
                    default: 20,
                    description: "Maximum number of results to return"
                  }
                },
                required: ["feed_name", "query"]
              }
            }
          ]
        }
      }')
      echo "<< $response" >> "$LOG_FILE"
      echo "$response"
      ;;
      
    "tools/call")
      # Extract tool parameters
      tool_method=$(echo "$line" | jq -r '.params.name // empty' 2>/dev/null)
      
      case "$tool_method" in
        "search-articles")
          # Extract search parameters
          query=$(echo "$line" | jq -r '.params.arguments.query // empty' 2>/dev/null)
          filter=$(echo "$line" | jq -r '.params.arguments.filter // "all"' 2>/dev/null)
          limit=$(echo "$line" | jq -r '.params.arguments.limit // 20' 2>/dev/null)
          include_content=$(echo "$line" | jq -r '.params.arguments.include_content // false' 2>/dev/null)
          
          # Build SQL query based on filter
          filter_clause=""
          case "$filter" in
            "starred")
              filter_clause="AND a.starred=1"
              ;;
            "unread")
              filter_clause="AND a.read=0"
              ;;
            "read")
              filter_clause="AND a.read=1"
              ;;
          esac
          
          # Execute search query
          if [ "$include_content" = "true" ]; then
            # Include content snippet
            sql_query="SELECT 
              a.title, 
              a.feedName, 
              a.author,
              a.articleURL,
              datetime(a.publishedDate, 'unixepoch') as published,
              CASE WHEN a.read=1 THEN 'read' ELSE 'unread' END as status,
              CASE WHEN a.starred=1 THEN 'starred' ELSE '' END as starred,
              substr(a.unrSummary, 1, 500) as content_preview,
              snippet(search_articles, 3, '[', ']', '...', 32) as matched_text
            FROM articles a 
            JOIN search_articles s ON a.search_articles_rowid = s.rowid 
            WHERE a.archived=0 
              $filter_clause
              AND search_articles MATCH '$query' 
            ORDER BY a.publishedDate DESC 
            LIMIT $limit;"
          else
            # Without content
            sql_query="SELECT 
              a.title, 
              a.feedName,
              a.author, 
              a.articleURL,
              datetime(a.publishedDate, 'unixepoch') as published,
              CASE WHEN a.read=1 THEN 'read' ELSE 'unread' END as status,
              CASE WHEN a.starred=1 THEN 'starred' ELSE '' END as starred,
              snippet(search_articles, 3, '[', ']', '...', 32) as matched_text
            FROM articles a 
            JOIN search_articles s ON a.search_articles_rowid = s.rowid 
            WHERE a.archived=0 
              $filter_clause
              AND search_articles MATCH '$query' 
            ORDER BY a.publishedDate DESC 
            LIMIT $limit;"
          fi
          
          # Log SQL query
          echo "\$\$ SQL: $sql_query" >> "$LOG_FILE"
          
          # Execute query and format results
          results=$(sqlite3 -json "$DB_PATH" "$sql_query" 2>&1)
          exit_code=$?
          
          if [ $exit_code -eq 0 ]; then
            # Parse results and create formatted response
            if [ -z "$results" ] || [ "$results" = "[]" ]; then
              result_text="No articles found matching query: $query"
            else
              # Count results
              count=$(echo "$results" | jq 'length')
              result_text="Found $count articles matching query: $query\n\n"
              
              # Format each result
              for i in $(seq 0 $((count - 1))); do
                article=$(echo "$results" | jq -r ".[$i]")
                title=$(echo "$article" | jq -r '.title // "Untitled"')
                feed=$(echo "$article" | jq -r '.feedName // "Unknown Feed"')
                author=$(echo "$article" | jq -r '.author // ""')
                url=$(echo "$article" | jq -r '.articleURL // ""')
                published=$(echo "$article" | jq -r '.published // ""')
                status=$(echo "$article" | jq -r '.status // ""')
                starred=$(echo "$article" | jq -r '.starred // ""')
                matched=$(echo "$article" | jq -r '.matched_text // ""')
                
                result_text="${result_text}$(($i + 1)). $title\n"
                result_text="${result_text}   Feed: $feed\n"
                [ -n "$author" ] && result_text="${result_text}   Author: $author\n"
                result_text="${result_text}   Published: $published\n"
                result_text="${result_text}   Status: $status"
                [ "$starred" = "starred" ] && result_text="${result_text} ⭐"
                result_text="${result_text}\n"
                [ -n "$matched" ] && result_text="${result_text}   Match: $matched\n"
                [ -n "$url" ] && result_text="${result_text}   URL: $url\n"
                
                if [ "$include_content" = "true" ]; then
                  content=$(echo "$article" | jq -r '.content_preview // ""')
                  [ -n "$content" ] && result_text="${result_text}   Preview: $content\n"
                fi
                
                result_text="${result_text}\n"
              done
            fi
            
            # Create response
            response=$(jq -cn --arg id "$id" --arg text "$result_text" '{
              jsonrpc: "2.0",
              id: ($id | tonumber),
              result: {
                content: [
                  {
                    type: "text",
                    text: $text
                  }
                ],
                isError: false
              }
            }')
          else
            # SQL error
            response=$(jq -cn --arg id "$id" --arg text "Database error: $results" '{
              jsonrpc: "2.0",
              id: ($id | tonumber),
              result: {
                content: [
                  {
                    type: "text",
                    text: $text
                  }
                ],
                isError: true
              }
            }')
          fi
          
          echo "<< $response" >> "$LOG_FILE"
          echo "$response"
          ;;
          
        "get-stats")
          # Get database statistics
          stats_query="SELECT 
            COUNT(*) as total_articles,
            SUM(CASE WHEN read=1 THEN 1 ELSE 0 END) as read_articles,
            SUM(CASE WHEN read=0 THEN 1 ELSE 0 END) as unread_articles,
            SUM(CASE WHEN starred=1 THEN 1 ELSE 0 END) as starred_articles,
            COUNT(DISTINCT feedName) as total_feeds
          FROM articles 
          WHERE archived=0;"
          
          results=$(sqlite3 -json "$DB_PATH" "$stats_query" 2>&1)
          exit_code=$?
          
          if [ $exit_code -eq 0 ]; then
            # Parse stats
            stats=$(echo "$results" | jq -r '.[0]')
            total=$(echo "$stats" | jq -r '.total_articles')
            read=$(echo "$stats" | jq -r '.read_articles')
            unread=$(echo "$stats" | jq -r '.unread_articles')
            starred=$(echo "$stats" | jq -r '.starred_articles')
            feeds=$(echo "$stats" | jq -r '.total_feeds')
            
            result_text="Unread Database Statistics:\n\n"
            result_text="${result_text}Total Articles: $total\n"
            result_text="${result_text}Read Articles: $read\n"
            result_text="${result_text}Unread Articles: $unread\n"
            result_text="${result_text}Starred Articles: $starred\n"
            result_text="${result_text}Total Feeds: $feeds"
            
            response=$(jq -cn --arg id "$id" --arg text "$result_text" '{
              jsonrpc: "2.0",
              id: ($id | tonumber),
              result: {
                content: [
                  {
                    type: "text",
                    text: $text
                  }
                ],
                isError: false
              }
            }')
          else
            response=$(create_error_response "$id" "-32603" "Database error: $results")
          fi
          
          echo "<< $response" >> "$LOG_FILE"
          echo "$response"
          ;;
          
        "list-feeds")
          # Get feed list
          limit=$(echo "$line" | jq -r '.params.arguments.limit // 30' 2>/dev/null)
          
          feeds_query="SELECT 
            feedName,
            COUNT(*) as article_count,
            SUM(CASE WHEN read=0 THEN 1 ELSE 0 END) as unread_count
          FROM articles 
          WHERE archived=0 AND feedName IS NOT NULL AND feedName != ''
          GROUP BY feedName 
          ORDER BY article_count DESC 
          LIMIT $limit;"
          
          results=$(sqlite3 -json "$DB_PATH" "$feeds_query" 2>&1)
          exit_code=$?
          
          if [ $exit_code -eq 0 ]; then
            count=$(echo "$results" | jq 'length')
            result_text="Top $count feeds by article count:\n\n"
            
            for i in $(seq 0 $((count - 1))); do
              feed=$(echo "$results" | jq -r ".[$i]")
              name=$(echo "$feed" | jq -r '.feedName')
              total=$(echo "$feed" | jq -r '.article_count')
              unread=$(echo "$feed" | jq -r '.unread_count')
              
              result_text="${result_text}$(($i + 1)). $name\n"
              result_text="${result_text}   Articles: $total (Unread: $unread)\n\n"
            done
            
            response=$(jq -cn --arg id "$id" --arg text "$result_text" '{
              jsonrpc: "2.0",
              id: ($id | tonumber),
              result: {
                content: [
                  {
                    type: "text",
                    text: $text
                  }
                ],
                isError: false
              }
            }')
          else
            response=$(create_error_response "$id" "-32603" "Database error: $results")
          fi
          
          echo "<< $response" >> "$LOG_FILE"
          echo "$response"
          ;;
          
        "search-by-feed")
          # Extract parameters
          feed_name=$(echo "$line" | jq -r '.params.arguments.feed_name // empty' 2>/dev/null)
          query=$(echo "$line" | jq -r '.params.arguments.query // empty' 2>/dev/null)
          filter=$(echo "$line" | jq -r '.params.arguments.filter // "all"' 2>/dev/null)
          limit=$(echo "$line" | jq -r '.params.arguments.limit // 20' 2>/dev/null)
          
          # Build filter clause
          filter_clause=""
          case "$filter" in
            "starred")
              filter_clause="AND a.starred=1"
              ;;
            "unread")
              filter_clause="AND a.read=0"
              ;;
            "read")
              filter_clause="AND a.read=1"
              ;;
          esac
          
          # Search within specific feed
          sql_query="SELECT 
            a.title,
            a.author,
            a.articleURL,
            datetime(a.publishedDate, 'unixepoch') as published,
            CASE WHEN a.read=1 THEN 'read' ELSE 'unread' END as status,
            CASE WHEN a.starred=1 THEN 'starred' ELSE '' END as starred,
            snippet(search_articles, 3, '[', ']', '...', 32) as matched_text
          FROM articles a 
          JOIN search_articles s ON a.search_articles_rowid = s.rowid 
          WHERE a.archived=0 
            AND a.feedName = '$feed_name'
            $filter_clause
            AND search_articles MATCH '$query' 
          ORDER BY a.publishedDate DESC 
          LIMIT $limit;"
          
          results=$(sqlite3 -json "$DB_PATH" "$sql_query" 2>&1)
          exit_code=$?
          
          if [ $exit_code -eq 0 ]; then
            if [ -z "$results" ] || [ "$results" = "[]" ]; then
              result_text="No articles found in feed '$feed_name' matching: $query"
            else
              count=$(echo "$results" | jq 'length')
              result_text="Found $count articles in '$feed_name' matching: $query\n\n"
              
              for i in $(seq 0 $((count - 1))); do
                article=$(echo "$results" | jq -r ".[$i]")
                title=$(echo "$article" | jq -r '.title // "Untitled"')
                author=$(echo "$article" | jq -r '.author // ""')
                url=$(echo "$article" | jq -r '.articleURL // ""')
                published=$(echo "$article" | jq -r '.published // ""')
                status=$(echo "$article" | jq -r '.status // ""')
                starred=$(echo "$article" | jq -r '.starred // ""')
                matched=$(echo "$article" | jq -r '.matched_text // ""')
                
                result_text="${result_text}$(($i + 1)). $title\n"
                [ -n "$author" ] && result_text="${result_text}   Author: $author\n"
                result_text="${result_text}   Published: $published\n"
                result_text="${result_text}   Status: $status"
                [ "$starred" = "starred" ] && result_text="${result_text} ⭐"
                result_text="${result_text}\n"
                [ -n "$matched" ] && result_text="${result_text}   Match: $matched\n"
                [ -n "$url" ] && result_text="${result_text}   URL: $url\n\n"
              done
            fi
            
            response=$(jq -cn --arg id "$id" --arg text "$result_text" '{
              jsonrpc: "2.0",
              id: ($id | tonumber),
              result: {
                content: [
                  {
                    type: "text",
                    text: $text
                  }
                ],
                isError: false
              }
            }')
          else
            response=$(create_error_response "$id" "-32603" "Database error: $results")
          fi
          
          echo "<< $response" >> "$LOG_FILE"
          echo "$response"
          ;;
          
        *)
          # Unknown tool
          response=$(create_error_response "$id" "-32601" "Tool not found: $tool_method")
          echo "$response"
          ;;
      esac
      ;;
      
    *)
      # Method not found
      response=$(create_error_response "$id" "-32601" "Method not found: $method")
      echo "$response"
      ;;
  esac
done || true