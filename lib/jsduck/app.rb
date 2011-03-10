require 'rubygems'
require 'jsduck/parser'
require 'jsduck/aggregator'
require 'jsduck/source_formatter'
require 'jsduck/class'
require 'jsduck/tree'
require 'jsduck/tree_icons'
require 'jsduck/members'
require 'jsduck/subclasses'
require 'jsduck/page'
require 'jsduck/timer'
require 'json'
require 'fileutils'
require 'parallel'

module JsDuck

  # The main application logic of jsduck
  class App
    # These are basically input parameters for app
    attr_accessor :output_dir
    attr_accessor :template_dir
    attr_accessor :input_files
    attr_accessor :verbose
    attr_accessor :export

    def initialize
      @output_dir = nil
      @template_dir = nil
      @input_files = []
      @verbose = false
      @export = nil
      @timer = Timer.new
    end

    # Call this after input parameters set
    def run
      clear_dir(@output_dir)
      if @export
        FileUtils.mkdir(@output_dir)
      else
        copy_template(@template_dir, @output_dir)
      end

      parsed_files = @timer.time(:parsing) { parallel_parse(@input_files) }
      result = @timer.time(:aggregating) { aggregate(parsed_files) }
      classes = @timer.time(:aggregating) { filter_classes(result) }

      if @export == :json
        @timer.time(:generating) { write_json(@output_dir, classes) }
      else
        @timer.time(:generating) { write_tree(@output_dir+"/output/tree.js", classes) }
        @timer.time(:generating) { write_members(@output_dir+"/output/members.js", classes) }
        @timer.time(:generating) { write_pages(@output_dir+"/output", classes) }
      end

      @timer.report if @verbose
    end

    # Parses the files in parallel using as many processes as available CPU-s
    def parallel_parse(filenames)
      src = SourceFormatter.new(@output_dir + "/source")
      Parallel.map(filenames) do |fname|
        puts "Parsing #{fname} ..." if @verbose
        code = IO.read(fname)
        {
          :filename => fname,
          :html_filename => @export ? "" : File.basename(src.write(code, fname)),
          :data => Parser.new(code).parse,
        }
      end
    end

    # Aggregates parsing results sequencially
    def aggregate(parsed_files)
      agr = Aggregator.new
      parsed_files.each do |file|
        puts "Aggregating #{file[:filename]} ..." if @verbose
        agr.aggregate(file[:data], file[:filename], file[:html_filename])
      end
      agr.result
    end

    # Filters out class-documentations, converting them to Class objects.
    # For each other type, prints a warning message and discards it
    def filter_classes(docs)
      classes = {}
      docs.each do |d|
        if d[:tagname] == :class
          classes[d[:name]] = Class.new(d, classes)
        else
          type = d[:tagname].to_s
          name = d[:name]
          file = d[:filename]
          line = d[:linenr]
          puts "Warning: Ignoring #{type}: #{name} in #{file} line #{line}"
        end
      end
      classes.values
    end

    # Given array of doc-objects, generates namespace tree and writes in
    # in JSON form into a file.
    def write_tree(filename, docs)
      tree = Tree.new.create(docs)
      icons = TreeIcons.new.extract_icons(tree)
      js = "Docs.classData = " + JSON.generate( tree ) + ";"
      js += "Docs.icons = " + JSON.generate( icons ) + ";"
      File.open(filename, 'w') {|f| f.write(js) }
    end

    # Given array of doc-objects, generates members data for search and writes in
    # in JSON form into a file.
    def write_members(filename, docs)
      members = Members.new.create(docs)
      js = "Docs.membersData = " + JSON.generate( {:data => members} ) + ";"
      File.open(filename, 'w') {|f| f.write(js) }
    end

    # Writes documentation page for each class
    # We do it in parallel using as many processes as available CPU-s
    def write_pages(path, docs)
      subclasses = Subclasses.new(docs)
      cache = {}
      Parallel.each(docs) do |cls|
        filename = path + "/" + cls[:name] + ".html"
        puts "Writing to #{filename} ..." if @verbose
        html = Page.new(cls, subclasses, cache).to_html
        File.open(filename, 'w') {|f| f.write(html) }
      end
    end

    # Writes JSON export file for each class
    def write_json(path, docs)
      subclasses = Subclasses.new(docs)
      cache = {}
      Parallel.each(docs) do |cls|
        filename = path + "/" + cls[:name] + ".json"
        puts "Writing to #{filename} ..." if @verbose
        hash = cls.to_hash
        if hash[:doc]
          hash[:doc] = DocFormatter.new(hash[:name]).format(hash[:doc])
        end
        json = JSON.pretty_generate(hash)
        File.open(filename, 'w') {|f| f.write(json) }
      end
    end

    def copy_template(template_dir, dir)
      puts "Copying template files to #{dir}..." if @verbose
      FileUtils.cp_r(template_dir, dir)
      FileUtils.mkdir(dir + "/output")
      FileUtils.mkdir(dir + "/source")
    end

    def clear_dir(dir)
      if File.exists?(dir)
        FileUtils.rm_r(dir)
      end
    end
  end

end