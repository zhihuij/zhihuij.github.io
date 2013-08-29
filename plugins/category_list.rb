# encoding: utf-8
module Jekyll
  class CategoryListTag < Liquid::Tag
    def render(context)
      html = ""
      categories = context.registers[:site].categories.keys

      max = 1
      categories.sort.each do |category|
        posts_in_category = context.registers[:site].categories[category].size
        max = posts_in_category if posts_in_category > max
      end

      categories.sort.each do |category|
        posts_in_category = context.registers[:site].categories[category].size
        category_dir = context.registers[:site].config['category_dir']
        category_url = File.join(category_dir, category.gsub(/_|\P{Word}/, '-').gsub(/-{2,}/, '-').downcase)
        style = "font-size: #{100 + (60 * Float(posts_in_category)/max)}%"
        html << "<a href='/#{category_url}/' style='#{style}'>#{category}(#{posts_in_category})</a> "
      end
      html
    end
  end
end

Liquid::Template.register_tag('category_list', Jekyll::CategoryListTag)
