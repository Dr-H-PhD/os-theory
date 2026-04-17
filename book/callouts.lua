-- Lua filter to convert callout patterns to styled boxes
-- Standard: > **Tip:** ..., > **Warning:** ..., > **Note:** ..., > **Info:** ...
-- Four-act: > **History:** ..., > **Puzzle:** ..., > **Real World:** ..., > **Exam:** ...

function BlockQuote(el)
  local first = el.content[1]
  if first and first.t == "Para" then
    local inlines = first.content
    if inlines[1] and inlines[1].t == "Strong" then
      local strong_content = pandoc.utils.stringify(inlines[1])

      local box_type = nil
      -- Standard callouts
      if strong_content:match("^Tip:?$") then
        box_type = "tipbox"
      elseif strong_content:match("^Warning:?$") then
        box_type = "warningbox"
      elseif strong_content:match("^Note:?$") then
        box_type = "notebox"
      elseif strong_content:match("^Info:?$") then
        box_type = "infobox"
      elseif strong_content:match("^Important:?$") then
        box_type = "warningbox"
      elseif strong_content:match("^Caution:?$") then
        box_type = "warningbox"
      -- Four-act callouts
      elseif strong_content:match("^History:?$") then
        box_type = "historybox"
      elseif strong_content:match("^The Story:?$") then
        box_type = "historybox"
      elseif strong_content:match("^Puzzle:?$") then
        box_type = "puzzlebox"
      elseif strong_content:match("^Real World:?$") then
        box_type = "realworldbox"
      elseif strong_content:match("^Exam:?$") then
        box_type = "exambox"
      elseif strong_content:match("^Exam Focus:?$") then
        box_type = "exambox"
      elseif strong_content:match("^Programmer:?$") then
        box_type = "programmerbox"
      end

      if box_type then
        -- Remove the label from content
        local new_inlines = {}
        local skip_space = true
        for i = 2, #inlines do
          if skip_space and inlines[i].t == "Space" then
            skip_space = false
          else
            table.insert(new_inlines, inlines[i])
          end
        end

        -- Build new content
        local new_content = pandoc.List()
        new_content:insert(pandoc.Para(new_inlines))
        for i = 2, #el.content do
          new_content:insert(el.content[i])
        end

        -- Return raw LaTeX
        local latex_begin = "\\begin{" .. box_type .. "}\n\\sloppy\n"
        local latex_end = "\n\\end{" .. box_type .. "}"

        return {
          pandoc.RawBlock("latex", latex_begin),
          pandoc.Div(new_content),
          pandoc.RawBlock("latex", latex_end)
        }
      end
    end
  end
  return el
end

-- Style table header cells: bold + coloured text
function Table(tbl)
  if tbl.head and tbl.head.rows and #tbl.head.rows > 0 then
    for _, row in ipairs(tbl.head.rows) do
      for _, cell in ipairs(row.cells) do
        for _, block in ipairs(cell.contents) do
          if block.t == "Para" or block.t == "Plain" then
            -- Wrap each header cell in bold + colour
            local old = block.content
            block.content = pandoc.List({
              pandoc.RawInline("latex", "{\\bfseries\\color{chapterblue} "),
            })
            block.content:extend(old)
            block.content:insert(pandoc.RawInline("latex", "}"))
          end
        end
      end
    end
  end
  return tbl
end
