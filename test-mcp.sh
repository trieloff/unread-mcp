#!/bin/bash

# Test script for Unread MCP server
echo "Testing Unread MCP Server..."

# Function to send request and show response
send_request() {
  local request="$1"
  local description="$2"
  
  echo -e "\n=== $description ==="
  echo "Request: $request"
  echo "$request" | ./unread-mcp.sh | jq '.'
}

# Test 1: Initialize
send_request '{"jsonrpc": "2.0", "method": "initialize", "params": {}, "id": 1}' "Initialize"

# Test 2: List tools
send_request '{"jsonrpc": "2.0", "method": "tools/list", "params": {}, "id": 2}' "List Tools"

# Test 3: Get stats
send_request '{"jsonrpc": "2.0", "method": "tools/call", "params": {"name": "get-stats", "arguments": {}}, "id": 3}' "Get Database Stats"

# Test 4: Search for AI articles
send_request '{"jsonrpc": "2.0", "method": "tools/call", "params": {"name": "search-articles", "arguments": {"query": "AI OR artificial intelligence", "filter": "starred", "limit": 5}}, "id": 4}' "Search Starred AI Articles"

# Test 5: Search for cycling
send_request '{"jsonrpc": "2.0", "method": "tools/call", "params": {"name": "search-articles", "arguments": {"query": "bicycle OR bike OR cycling", "limit": 5, "include_content": true}}, "id": 5}' "Search Cycling Articles with Content"

# Test 6: List feeds
send_request '{"jsonrpc": "2.0", "method": "tools/call", "params": {"name": "list-feeds", "arguments": {"limit": 10}}, "id": 6}' "List Top 10 Feeds"

# Test 7: Search within specific feed
send_request '{"jsonrpc": "2.0", "method": "tools/call", "params": {"name": "search-by-feed", "arguments": {"feed_name": "The Radavist", "query": "bike"}}, "id": 7}' "Search 'bike' in The Radavist"

# Test 8: Boolean NOT search
send_request '{"jsonrpc": "2.0", "method": "tools/call", "params": {"name": "search-articles", "arguments": {"query": "javascript NOT react", "limit": 5}}, "id": 8}' "Search JavaScript NOT React"

# Test 9: Phrase search
send_request '{"jsonrpc": "2.0", "method": "tools/call", "params": {"name": "search-articles", "arguments": {"query": "\"climate change\"", "limit": 5}}, "id": 9}' "Search Exact Phrase 'climate change'"

echo -e "\n=== Test Complete ==="