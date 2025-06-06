-- TODO: Automatically paste definitions into the source file
-- TODO: Automatically paste namespaces
-- TODO: Automatically detect matching namespaces in source file
-- TODO: Automatically open source file in another window

---@class flipp.lsp.clangd.Symbol
---@field name string
---@field kind integer
---@field detail? string
---@field range flipp.Range
---@field selectionRange flipp.Range
---@field children? flipp.lsp.clangd.Symbol[]

---@class flipp.lsp.clangd.DefinitionResult
---@field range flipp.Range
---@field uri string

---@class flipp.Symbol
---@field name string
---@field kind integer
---@field detail? string
---@field children? flipp.Symbol[]

--- @class flipp.Definition
--- @field decl_func TSNode
--- @field classifiers TSNode[]
--- @field namespaces TSNode[]
--- @field classes TSNode[]

---@class flipp.Position
---@field line integer
---@field character integer

---@class flipp.Range
---@field start flipp.Position
---@field end flipp.Position
---@field block? boolean -- defaults to false

---Get the cursor selection in the current window
---Positions are 0 indexed
---@return flipp.Range
local function get_cursor_range()
  local pos_start = vim.fn.getpos(".") -- cursor position
  local pos_end = vim.fn.getpos("v")   -- defaults to '.' when not in visual mode

  -- Normalize to 0-indexed to match clangd
  local start_row = math.min(pos_start[2], pos_end[2]) - 1
  local end_row = math.max(pos_start[2], pos_end[2]) - 1
  local start_col = math.min(pos_start[3], pos_end[3]) - 1
  local end_col = math.max(pos_start[3], pos_end[3]) - 1

  -- Correct the range based on the current mode
  local mode = vim.fn.mode()
  local block = mode == "\22"
  if mode == "V" then
    start_col = 0
    end_col = vim.v.maxcol
  end

  ---@type flipp.Range
  return {
    ["start"] = { line = start_row, character = start_col },
    ["end"] = { line = end_row, character = end_col },
    ["block"] = block
  }
end

---@param node TSNode
---@return flipp.Range
local function get_node_range(node)
  local range_int = vim.treesitter.get_range(node, 0)

  ---@type flipp.Range
  return {
    ["start"] = { line = range_int[1], character = range_int[2] },
    ["end"] = { line = range_int[4], character = range_int[5] }
  }
end

---@param r1 flipp.Range
---@param r2 flipp.Range
---@return boolean
local function is_range_intersect(r1, r2)
  -- FIXME: Handle block intersections properly
  if r1["end"].line < r2["start"].line then return false end
  if r1["end"].line == r2["start"].line and r1["end"].character < r2["start"].character then return false end
  if r1["start"].line > r2["end"].line then return false end
  if r1["start"].line == r2["end"].line and r1["start"].character > r2["end"].character then return false end
  return true
end

---@param decl_node TSNode
---@return TSNode|nil node TSNode of type function_declarator if not nil
local function find_decl_func_node(decl_node)
  if not decl_node then return nil end
  if decl_node:type() == "function_declarator" then
    return decl_node
  end

  for child in decl_node:iter_children() do
    local found = find_decl_func_node(child)
    if found then return found end
  end
  return nil
end

---@param node TSNode
---@return boolean callable true if node has a function_declarator as eventual child
local function is_callable_declaration(node)
  return find_decl_func_node(node) ~= nil
end

---@return TSNode[]
local function get_declaration_nodes()
  local ts = vim.treesitter
  local parser = ts.get_parser(0, nil, { error = false })
  if not parser then
    vim.notify("Failed to create treesitter parser", vim.log.levels.ERROR)
    return {}
  end

  local query = ts.query.parse("cpp", [[
(declaration
  declarator: [(function_declarator) (reference_declarator) (pointer_declarator)]
  ) @decl

(field_declaration
  declarator: [(function_declarator) (reference_declarator) (pointer_declarator)]
  !default_value
  ) @decl
]])


  local tree = parser:parse()
  if not tree then
    vim.notify("Failed to parse tree", vim.log.levels.WARN)
    return {}
  end

  local root = tree[1]:root()
  local nodes = {}
  for _, node in query:iter_captures(root, 0) do
    if is_callable_declaration(node) then
      table.insert(nodes, node)
    end
  end
  return nodes
end

---@param decl TSNode
---@return flipp.Definition|nil
local function build_definition_from_declaration(decl)
  local decl_func_node = find_decl_func_node(decl)
  if not decl_func_node then return nil end

  ---@type flipp.Definition
  local def = {
    decl_func = decl_func_node,
    classifiers = {},
    namespaces = {},
    classes = {},
  }

  ---@type TSNode|nil
  local n = decl_func_node
  local outer = false
  while n ~= nil do
    if n:type() == "declaration" or n:type() == "field_declaration" then
      outer = true
    elseif n:type() == "namespace_definition" then
      local name_node = n:named_child(0) --[[@as TSNode]]
      table.insert(def.namespaces, 1, name_node)
    elseif n:type() == "class_specifier" then
      local name_node = n:named_child(0) --[[@as TSNode]]
      table.insert(def.classes, 1, name_node)
    end

    while not outer and n:prev_sibling() ~= nil do
      n = n:prev_sibling() --[[@as TSNode]]
      table.insert(def.classifiers, 1, n)
    end
    n = n:parent()
  end

  return def
end

---@param node TSNode
---@return string
local function decl_func_node_to_str(node)
  if node:type() ~= "function_declarator" then return "" end

  local ts = vim.treesitter
  local outStr = ts.get_node_text(node, 0):gsub("%s+final", ""):gsub("%s+override", "")
  return outStr .. " {}"
end

---@param nodes TSNode[]
---@return string
local function namespace_nodes_to_str(nodes)
  if #nodes == 0 then return "" end

  local ts = vim.treesitter
  local strs = vim.tbl_map(function(node) return ts.get_node_text(node, 0) end, nodes)
  return table.concat(strs, "::") .. "::"
end

---@param nodes TSNode[]
---@return string
local function class_nodes_to_str(nodes)
  if #nodes == 0 then return "" end

  local ts = vim.treesitter
  local strs = vim.tbl_map(function(node) return ts.get_node_text(node, 0) end, nodes)
  return table.concat(strs, "::") .. "::"
end

---@param nodes TSNode[]
---@return string
local function classifier_nodes_to_str(nodes)
  local ts = vim.treesitter
  local strs = vim.tbl_map(function(node) return ts.get_node_text(node, 0) end, nodes)
  local s = ""
  for _, w in ipairs(strs) do
    if w == "virtual" or w == "static" then
    elseif w == "*" or w == "&" then
      s = s .. w
    else
      s = s .. w .. " "
    end
  end
  return s
end

---@param def flipp.Definition
---@return string
local function def_to_string(def)
  local func_str = decl_func_node_to_str(def.decl_func)
  local namespace_str = namespace_nodes_to_str(def.namespaces)
  local class_str = class_nodes_to_str(def.classes)
  local classifier_str = classifier_nodes_to_str(def.classifiers)

  return classifier_str .. namespace_str .. class_str .. func_str
end

local M = {}

---@class flipp.Opts

---@type flipp.Opts
local default_opts = {}

---@param opts flipp.Opts|nil: opts
M.setup = function(opts)
  opts = opts or default_opts

  vim.api.nvim_create_user_command('FlippGenerate', function()
      M.get_fully_qualified_undefined_selected_declarations()
    end,
    { nargs = 0, range = true })
end

---@param node TSNode
---@return boolean
local function has_definition(node)
  local client = vim.lsp.get_clients({ bufnr = 0, name = "clangd" })[1]
  if vim.tbl_isempty(client) then
    vim.notify("Clangd is not running - cannot determine existing definitions", vim.log.levels.WARN)
    return false
  end

  local node_range = get_node_range(node)
  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  params.position = {
    line = node_range.start.line, character = node_range.start.character
  }

  --- PERF: Can this be made async again - or perhaps make outer funcs async
  local resp = client:request_sync("textDocument/definition", params)
  if not resp then
    vim.notify("LSP timed out", vim.log.levels.WARN)
    return false
  end

  local result, err = resp.result, resp.err
  if err then
    vim.notify("LSP error: " .. err.message, vim.log.levels.ERROR)
    return false
  end

  if not result or vim.tbl_isempty(result) then return false end

  for _, data in ipairs(result) do
    if not is_range_intersect(node_range, data.range) then return true end
  end

  return false
end


function M.get_fully_qualified_undefined_selected_declarations()
  local cursor_range = get_cursor_range()
  local decl_nodes = get_declaration_nodes()

  ---@type flipp.Definition[]
  local defs = {}
  for _, decl_node in ipairs(decl_nodes) do
    local node_range = get_node_range(decl_node)
    local func_node = find_decl_func_node(decl_node)
    if func_node and is_range_intersect(cursor_range, node_range) and not has_definition(func_node) then
      local def = build_definition_from_declaration(decl_node)
      if def then
        table.insert(defs, def)
      end
    end
  end

  if #defs > 0 then
    vim.fn.setreg("d",
      vim.tbl_map(function(def) return def_to_string(def) end, defs),
      "l"
    )
    vim.notify("Copied " .. #defs .. " definition to 'd' register", vim.log.levels.INFO)
  end
end

return M
