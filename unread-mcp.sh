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

# Send JSON-RPC response
send_response() {
    local response="$1"
    echo "$response"
    echo "<< $response" >> "$LOG_FILE"
}

# Error response
error_response() {
    local id="$1"
    local code="$2"
    local message="$3"
    local response
    response=$(jq -cn --argjson id "$id" --argjson code "$code" --arg message "$message" '{
        jsonrpc: "2.0",
        id: $id,
        error: {
            code: $code,
            message: $message
        }
    }')
    send_response "$response"
}

# Success response
success_response() {
    local id="$1"
    local result="$2"
    local response
    response=$(jq -cn --argjson id "$id" --argjson result "$result" '{
        jsonrpc: "2.0",
        id: $id,
        result: $result
    }')
    send_response "$response"
}

# Helper function to create JSON responses (backward compatibility)
create_json_response() {
  local id="$1"
  local content="$2"
  local response=$(jq -cn --arg id "$id" --arg content "$content" '{jsonrpc: "2.0", id: ($id | tonumber), result: $content | fromjson}')
  echo "<< $response" >> "$LOG_FILE"
  echo "$response"
}

# Helper function to create error responses (backward compatibility)
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

# Parse query for special directives and extract search parameters
parse_query() {
    local query="$1"
    
    # Initialize variables
    SEARCH_TYPE="articles"
    FEED_NAME=""
    STATUS_FILTER="all"
    REMAINING_QUERY=""
    
    # Parse directives from query
    local words=()
    local remaining_words=()
    
    # Split query into words, respecting quoted strings  
    while IFS= read -r word; do
        words+=("$word")
    done < <(echo "$query" | grep -oE 'feed:"[^"]*"|[^[:space:]]+')
    
    for word in "${words[@]}"; do
        if [[ "$word" =~ ^type: ]]; then
            # Extract search type
            SEARCH_TYPE="${word#type:}"
        elif [[ "$word" =~ ^feed: ]]; then
            # Extract feed name, removing quotes if present
            FEED_NAME="${word#feed:}"
            FEED_NAME="${FEED_NAME#\"}"
            FEED_NAME="${FEED_NAME%\"}"
        elif [[ "$word" =~ ^status: ]]; then
            # Extract status filter
            STATUS_FILTER="${word#status:}"
        else
            # Regular search word
            remaining_words+=("$word")
        fi
    done
    
    # Join remaining words for content search
    REMAINING_QUERY="${remaining_words[*]}"
    
    # If no remaining query and no specific type, default to recent articles
    if [[ -z "$REMAINING_QUERY" && "$SEARCH_TYPE" == "articles" ]]; then
        REMAINING_QUERY="*"
    fi
}

# Format dual response for cross-client compatibility
format_dual_response() {
    local search_results="$1"
    local query="$2"
    local search_type="${3:-search}"
    
    local count
    count=$(echo "$search_results" | jq length)
    
    if [[ "$count" -eq 0 ]]; then
        # No results
        jq -cn --arg query "$query" '{
            content: [
                {
                    type: "text",
                    text: ("No results found for: " + $query)
                }
            ],
            results: []
        }'
        return
    fi
    
    # Format content for Claude (readable text)
    local content_text
    if [[ "$search_type" == "feeds" ]]; then
        content_text="Found $count feeds:\n\n$(echo "$search_results" | jq -r '.[] | "• " + .feedName + " (" + (.article_count | tostring) + " articles, " + (.unread_count | tostring) + " unread)"' | nl)"
    elif [[ "$search_type" == "stats" ]]; then
        content_text=$(echo "$search_results" | jq -r '.[0] | "Unread Database Statistics:\n\nTotal Articles: " + (.total_articles | tostring) + "\nRead Articles: " + (.read_articles | tostring) + "\nUnread Articles: " + (.unread_articles | tostring) + "\nStarred Articles: " + (.starred_articles | tostring) + "\nTotal Feeds: " + (.total_feeds | tostring)')
    else
        content_text="Found $count articles for '$query':\n\n$(echo "$search_results" | jq -r '.[] | "• " + .title + " (" + .feedName + ")\n  ID: " + .uniqueID + "\n  Published: " + .published + "\n  Status: " + .status + (if .starred == "starred" then " ⭐" else "" end) + "\n  Preview: " + (.content_preview // "")[0:200] + "...\n"')"
    fi
    
    # Format results for OpenAI (structured data)
    local openai_results
    if [[ "$search_type" == "feeds" ]]; then
        openai_results=$(echo "$search_results" | jq '[.[] | {
            id: .feedName,
            title: .feedName,
            text: ("Feed with " + (.article_count | tostring) + " articles (" + (.unread_count | tostring) + " unread)"),
            url: null
        }]')
    elif [[ "$search_type" == "stats" ]]; then
        openai_results=$(echo "$search_results" | jq '[.[0] | {
            id: "stats",
            title: "Database Statistics",
            text: ("Total: " + (.total_articles | tostring) + ", Read: " + (.read_articles | tostring) + ", Unread: " + (.unread_articles | tostring) + ", Starred: " + (.starred_articles | tostring) + ", Feeds: " + (.total_feeds | tostring)),
            url: null
        }]')
    else
        openai_results=$(echo "$search_results" | jq '[.[] | {
            id: .uniqueID,
            title: .title,
            text: (.content_preview // (.title + " from " + .feedName)),
            url: .uniqueID
        }]')
    fi
    
    # Combine both formats
    jq -cn --arg text "$content_text" --argjson results "$openai_results" '{
        content: [
            {
                type: "text",
                text: $text
            }
        ],
        results: $results
    }'
}

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
      tools=$(jq -cn '[
        {
          name: "search",
          description: "Search through articles in your Unread RSS reader database using keyword-based fulltext search. Supports special query syntax: use 'type:stats' for database statistics, 'type:feeds' to list feeds, 'feed:name' to search within specific feed, 'status:read/unread/starred' to filter by status. Returns results with article IDs for content retrieval.",
          inputSchema: {
            type: "object",
            properties: {
              query: {
                type: "string",
                description: "Search query with optional directives. Examples: python (search articles), type:stats (show database stats), type:feeds (list feeds), feed:Ars_Technica python (search python in feed), status:starred AI (search starred AI articles). Use * or empty for recent articles."
              },
              limit: {
                type: "integer",
                description: "Maximum number of results (default: 20)",
                default: 20,
                minimum: 1,
                maximum: 100
              }
            },
            required: ["query"]
          },
          outputSchema: {
            type: "object",
            properties: {
              content: {
                type: "array",
                items: {
                  type: "object",
                  properties: {
                    type: { type: "string" },
                    text: { type: "string" }
                  }
                }
              },
              results: {
                type: "array",
                items: {
                  type: "object",
                  properties: {
                    id: { type: "string" },
                    title: { type: "string" },
                    text: { type: "string" },
                    url: { type: ["string", "null"] }
                  }
                }
              }
            }
          }
        },
        {
          name: "fetch",
          description: "Retrieve the full content of a specific article by its ID. Use article IDs from search results.",
          inputSchema: {
            type: "object",
            properties: {
              url: {
                type: "string",
                description: "Article ID or URL from search results"
              }
            },
            required: ["url"]
          },
          outputSchema: {
            type: "object",
            properties: {
              content: {
                type: "array",
                items: {
                  type: "object",
                  properties: {
                    type: { type: "string" },
                    text: { type: "string" }
                  }
                }
              },
              title: { type: "string" },
              url: { type: "string" }
            }
          }
        }
      ]')
      
      success_response "$id" "{ \"tools\": $tools }"
      ;;
      
    "tools/call")
      # Extract tool parameters
      tool_method=$(echo "$line" | jq -r '.params.name // empty' 2>/dev/null)
      
      case "$tool_method" in
        "search")
          # Extract search parameters
          query=$(echo "$line" | jq -r '.params.arguments.query // empty' 2>/dev/null)
          limit=$(echo "$line" | jq -r '.params.arguments.limit // 20' 2>/dev/null)
          
          # Parse query for directives
          parse_query "$query"
          
          # Use parsed values
          search_type="$SEARCH_TYPE"
          feed_name="$FEED_NAME"
          filter="$STATUS_FILTER"
          query="$REMAINING_QUERY"
          
          if [[ -z "$query" ]] && [[ "$search_type" == "articles" ]]; then
            error_response "$id" -32602 "Missing required parameter: query"
            return
          fi
          
          # Handle different search types
          case "$search_type" in
            "feeds")
              # List feeds
              sql_query="SELECT 
                feedName,
                COUNT(*) as article_count,
                SUM(CASE WHEN read=0 THEN 1 ELSE 0 END) as unread_count
              FROM articles 
              WHERE archived=0 AND feedName IS NOT NULL AND feedName != ''
              GROUP BY feedName 
              ORDER BY article_count DESC 
              LIMIT $limit;"
              ;;
            "stats")
              # Get statistics
              sql_query="SELECT 
                COUNT(*) as total_articles,
                SUM(CASE WHEN read=1 THEN 1 ELSE 0 END) as read_articles,
                SUM(CASE WHEN read=0 THEN 1 ELSE 0 END) as unread_articles,
                SUM(CASE WHEN starred=1 THEN 1 ELSE 0 END) as starred_articles,
                COUNT(DISTINCT feedName) as total_feeds
              FROM articles 
              WHERE archived=0;"
              ;;
            *)
              # Article search
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
              
              # Add feed filter if specified
              feed_clause=""
              if [[ -n "$feed_name" ]]; then
                feed_clause="AND a.feedName = '$feed_name'"
              fi
              
              # Check if query is empty or wildcard
              if [[ -z "$query" ]] || [[ "$query" = "*" ]]; then
                sql_query="SELECT 
                  a.uniqueID,
                  a.title, 
                  a.feedName,
                  a.author, 
                  a.articleURL,
                  datetime(a.publishedDate, 'unixepoch') as published,
                  datetime(a.mark_read_date, 'unixepoch') as read_date,
                  CASE WHEN a.read=1 THEN 'read' ELSE 'unread' END as status,
                  CASE WHEN a.starred=1 THEN 'starred' ELSE '' END as starred,
                  substr(a.unrSummary, 1, 300) as content_preview
                FROM articles a 
                WHERE a.archived=0 
                  AND a.read=1
                  AND a.mark_read_date IS NOT NULL
                  $filter_clause
                  $feed_clause
                ORDER BY a.mark_read_date DESC 
                LIMIT $limit;"
              else
                sql_query="SELECT 
                  a.uniqueID,
                  a.title, 
                  a.feedName,
                  a.author, 
                  a.articleURL,
                  datetime(a.publishedDate, 'unixepoch') as published,
                  CASE WHEN a.read=1 THEN 'read' ELSE 'unread' END as status,
                  CASE WHEN a.starred=1 THEN 'starred' ELSE '' END as starred,
                  substr(a.unrSummary, 1, 300) as content_preview,
                  snippet(search_articles, 3, '[', ']', '...', 32) as matched_text
                FROM articles a 
                JOIN search_articles s ON a.search_articles_rowid = s.rowid 
                WHERE a.archived=0 
                  $filter_clause
                  $feed_clause
                  AND search_articles MATCH '$query' 
                ORDER BY a.publishedDate DESC 
                LIMIT $limit;"
              fi
              ;;
          esac
          
          # Log SQL query
          echo "\$\$ SQL: $sql_query" >> "$LOG_FILE"
          
          # Execute query
          results=$(sqlite3 -json "$DB_PATH" "$sql_query" 2>&1)
          exit_code=$?
          
          if [[ $exit_code -eq 0 ]]; then
            # Format dual response
            # Use original query for display purposes
            original_query=$(echo "$line" | jq -r '.params.arguments.query // empty' 2>/dev/null)
            mcp_result=$(format_dual_response "$results" "$original_query" "$search_type")
            success_response "$id" "$mcp_result"
          else
            error_response "$id" -32603 "Database error: $results"
          fi
          ;;
          
        "fetch")
          # Extract article ID/URL
          article_url=$(echo "$line" | jq -r '.params.arguments.url // empty' 2>/dev/null)
          
          if [[ -z "$article_url" ]]; then
            error_response "$id" -32602 "Missing required parameter: url"
            return
          fi
          
          # Get full article content
          article_query="SELECT 
            a.uniqueID,
            a.title,
            a.feedName,
            a.author,
            a.articleURL,
            datetime(a.publishedDate, 'unixepoch') as published,
            datetime(a.mark_read_date, 'unixepoch') as read_date,
            CASE WHEN a.read=1 THEN 'read' ELSE 'unread' END as status,
            CASE WHEN a.starred=1 THEN 'starred' ELSE '' END as starred,
            a.unrSummary,
            LENGTH(a.CompressedHtmlBlob) as has_html
          FROM articles a 
          WHERE a.uniqueID = '$article_url'
          LIMIT 1;"
          
          results=$(sqlite3 -json "$DB_PATH" "$article_query" 2>&1)
          exit_code=$?
          
          if [[ $exit_code -eq 0 ]]; then
            if [[ -z "$results" ]] || [[ "$results" = "[]" ]]; then
              error_response "$id" -32603 "Article not found with ID: $article_url"
            else
              # Parse article data
              article=$(echo "$results" | jq -r '.[0]')
              title=$(echo "$article" | jq -r '.title // "Untitled"')
              feed=$(echo "$article" | jq -r '.feedName // "Unknown Feed"')
              author=$(echo "$article" | jq -r '.author // ""')
              url=$(echo "$article" | jq -r '.articleURL // ""')
              published=$(echo "$article" | jq -r '.published // ""')
              read_date=$(echo "$article" | jq -r '.read_date // ""')
              status=$(echo "$article" | jq -r '.status // ""')
              starred=$(echo "$article" | jq -r '.starred // ""')
              summary=$(echo "$article" | jq -r '.unrSummary // ""')
              has_html=$(echo "$article" | jq -r '.has_html // "0"')
              
              # Extract full content if available
              full_content=""
              if [[ "$has_html" != "0" ]] && [[ "$has_html" != "null" ]]; then
                temp_file="/tmp/article_${article_url}_compressed.zlib"
                sqlite3 "$DB_PATH" "SELECT writefile('$temp_file', CompressedHtmlBlob) FROM articles WHERE uniqueID = '$article_url';" 2>/dev/null
                
                if [[ -f "$temp_file" ]]; then
                  full_content=$(python3 -c "
import zlib
import re
import html
try:
    with open('$temp_file', 'rb') as f:
        compressed = f.read()
    html_content = zlib.decompress(compressed).decode('utf-8')
    text = re.sub('<[^<]+?>', ' ', html_content)
    text = html.unescape(text)
    text = ' '.join(text.split())
    print(text)
except Exception:
    print('Error decompressing content')
" 2>/dev/null)
                  rm -f "$temp_file"
                fi
              fi
              
              # Build content text
              content_text="Article: $title\n\nFeed: $feed\n"
              [[ -n "$author" ]] && content_text="${content_text}Author: $author\n"
              content_text="${content_text}Published: $published\n"
              [[ -n "$read_date" ]] && content_text="${content_text}Read on: $read_date\n"
              content_text="${content_text}Status: $status"
              [[ "$starred" = "starred" ]] && content_text="${content_text} ⭐"
              content_text="${content_text}\n"
              [[ -n "$url" ]] && content_text="${content_text}URL: $url\n"
              content_text="${content_text}\n--- Content ---\n\n"
              
              # Use full content if available, otherwise summary
              if [[ -n "$full_content" ]] && [[ "$full_content" != "Error decompressing content" ]]; then
                content_text="${content_text}$full_content"
              elif [[ -n "$summary" ]]; then
                content_text="${content_text}[Summary only - full HTML content not available]\n\n$summary"
              else
                content_text="${content_text}[No content available]"
              fi
              
              # Format dual response
              mcp_result=$(jq -cn --arg text "$content_text" --arg title "$title" --arg url "$article_url" '{
                content: [
                  {
                    type: "text",
                    text: $text
                  }
                ],
                title: $title,
                url: $url
              }')
              success_response "$id" "$mcp_result"
            fi
          else
            error_response "$id" -32603 "Database error: $results"
          fi
          ;;
          
        # Legacy tool support for backward compatibility
        "search-articles"|"get-article"|"get-stats"|"list-feeds"|"search-by-feed")
          case "$tool_method" in
            "get-stats")
              response=$(create_json_response "$id" '{
                "content": [
                  {
                    "type": "text",
                    "text": "Please use the search tool with search_type=\"stats\" and query=\"*\" instead."
                  }
                ],
                "isError": false
              }')
              ;;
            "list-feeds")
              response=$(create_json_response "$id" '{
                "content": [
                  {
                    "type": "text",
                    "text": "Please use the search tool with search_type=\"feeds\" and query=\"*\" instead."
                  }
                ],
                "isError": false
              }')
              ;;
            *)
              response=$(create_json_response "$id" '{
                "content": [
                  {
                    "type": "text",
                    "text": "This tool has been consolidated. Please use the \"search\" tool for searching articles or \"fetch\" tool for getting article content."
                  }
                ],
                "isError": false
              }')
              ;;
          esac
          echo "<< $response" >> "$LOG_FILE"
          echo "$response"
          ;;
          
        *)
          # Unknown tool
          error_response "$id" -32601 "Tool not found: $tool_method"
          ;;
      esac
      ;;
      
    "resources/list")
      # OpenAI compatibility - return empty resources
      success_response "$id" '{ "resources": [] }'
      ;;
    "prompts/list")
      # OpenAI compatibility - return empty prompts
      success_response "$id" '{ "prompts": [] }'
      ;;
    *)
      # Method not found
      error_response "$id" -32601 "Method not found: $method"
      ;;
  esac
done || true