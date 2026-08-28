-- Hoist title from metadata into the first header

-- This lua-filter is for extracting the first H1 in the document and hoisting it up to be
-- the document title.  This distorts the Markdown format somewhat as subsequent H1 elements
-- are treated differently. Alternatively, you can just set `title` in the metadata

local found_title = nil
Header = function (header)
  -- Preserve the first H1 in case we need to hoist it
  if found_title == nil and header.level == 1 then
    found_title = header.content
  end
  return header
end

Pandoc = function (doc)
  if found_title then
    -- If we need to hoist it...
    if doc.meta.title == nil then
      -- Set the doc title
      doc.meta.title = found_title
      -- Remove the first H1 as it's now the title.
      table.remove(doc.blocks, 1) 
    end
  end

  -- Deduce year from metadata if not set
  if doc.meta.year == nil then
    if doc.meta.date and doc.meta.date.year then
      doc.meta.year = doc.meta.date.year
    else
      doc.meta.year = os.date("%Y")
    end
  end

  -- Convert pdfulator_features to a string to use as a HTML class string for CSS
  if type(doc.meta.pdfulator_features) == "table" then
    local features = {}
    for k, v in pairs(doc.meta.pdfulator_features) do
      table.insert(features, pandoc.utils.stringify(v))
    end
    doc.meta.pdfulator_features = table.concat(features, " ")
  end

  return doc
end