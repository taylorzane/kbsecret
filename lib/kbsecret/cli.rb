# frozen_string_literal: true

require_relative "cli/command"

require "slop"
require "dreck"
require "abbrev"
require "pastel"
require "io/console"
require "forwardable"

module KBSecret
  # An encapsulation of useful methods for kbsecret's CLI.
  # Most methods in this class assume that they are being called from the context of
  # a command-line utility.
  class CLI
    extend Forwardable

    # Abbreviations for record types (e.g., `env` for `environment`).
    TYPE_ALIASES = Abbrev.abbrev Record.record_types

    # ANSI color objects for prettifying output.
    GREEN, YELLOW, RED = ->(p) { [p.green, p.yellow, p.red].map(&:detach) }.call(Pastel.new)

    # @return [Slop::Result, nil] the result of option parsing, if requested
    #   via {#slop}
    attr_reader :opts

    # @return [Dreck::Result, nil] the result of trailing argument parsing, if
    #   requested via {#dreck}
    attr_reader :args

    # @return [Session, nil] the session associated with the command, if requested
    #   via {#ensure_session!}
    attr_reader :session

    class << self
      # Print an error message and terminate.
      # @param msg [String] the message to print
      # @return [void]
      # @note This method does not return!
      def die(msg)
        fatal = ENV["NO_COLOR"] ? "Fatal" : RED["Fatal"]
        abort "#{fatal}: #{msg}"
      end

      # Finds a reasonable default field separator by checking the environment first
      #  and then falling back to ":".
      # @return [String] the field separator
      def ifs
        ENV["IFS"] || ":"
      end

      # @return [IO] the IO object corresponding to the current standard input
      # @note Internal `kbsecret` commands should use this, and not `STDIN`.
      def stdin
        $stdin
      end

      # @return [IO] the IO object corresponding to the current standard output
      # @note Internal `kbsecret` commands should use this, and not `STDOUT`.
      def stdout
        $stdout
      end

      # @return [IO] the IO object corresponding to the current standard error
      # @note Internal `kbsecret` commands should use this, and not `STDERR`.
      def stderr
        $stderr
      end

      # Searches for an executable on the user's `$PATH`.
      # @param util [String] the name of the executable to search for.
      # @return [Boolean] whether or not `util` is available on the `$PATH`.
      # @example
      #  CLI.installed? "foo" # => false
      #  CLI.installed? "gcc" # => true
      def installed?(util)
        ENV["PATH"].split(File::PATH_SEPARATOR).any? do |path|
          File.executable?(File.join(path, util))
        end
      end
    end

    # Encapsulate both the options and trailing arguments passed to a `kbsecret` command.
    # @yield [CLI] the {CLI} instance to specify
    # @return [CLI] the command's initial state
    # @example
    #  cmd = KBSecret::CLI.create do |c|
    #    c.slop do |o|
    #      o.string "-s", "--session", "session label"
    #      o.bool "-f", "--foo", "whatever"
    #    end
    #
    #    c.dreck do
    #      string :name
    #    end
    #
    #    c.ensure_session!
    #  end
    #
    #  cmd.opts # => Slop::Result
    #  cmd.args # => Dreck::Result
    def self.create(argv = ARGV, &block)
      CLI.new(argv, &block)
    end

    # @api private
    # @deprecated see {create}
    def initialize(argv = ARGV)
      @argv = argv.dup
      guard { yield self }
    end

    def_delegators :"self.class", :die, :ifs, :stdin, :stdout, :stderr, :installed?

    # Parse options for a `kbsecret` command, adding some default options for
    #  introspection, verbosity, and help output.
    # @param cmds [Array<String>] additional commands to print in `--introspect-flags`
    # @param errors [Boolean] whether or not to produce Slop errors
    # @return [Slop::Result] the result of argument parsing
    # @note This should be called within the block passed to {#initialize}.
    def slop(cmds: [], errors: true)
      @opts = Slop.parse @argv, suppress_errors: !errors do |o|
        o.separator "Options:"

        yield o

        o.bool "-V", "--verbose", "produce more verbose output"
        o.bool "-w", "--no-warn", "suppress warning messages"
        o.bool "--debug", "produce full backtraces on errors"

        o.on "-h", "--help", "show this help message" do
          puts o.to_s prefix: "  "
          exit
        end

        o.on "--introspect-flags", "dump recognized flags and subcommands" do
          comp = o.options.flat_map(&:flags) + cmds
          puts comp.join "\n"
          exit
        end
      end

      @argv = @opts.args
    end

    # Parse trailing arguments for a `kbsecret` command, using the elements remaining
    #  after options have been removed and interpreted via {#slop}.
    # @param errors [Boolean] whether or not to produce (strict) Dreck errors
    # @note *If* {#slop} is called, it must be called before this.
    def dreck(errors: true, &block)
      @args = Dreck.parse @argv, strict: errors do
        instance_eval(&block)
      end
    end

    # Ensure that a session passed in as an option or argument already exists
    #   (i.e., is already configured).
    # @param where [Symbol] Where to look for the session label to test.
    #   If `:option` is passed, then the session is expected to be the value of
    #   the `--session` option. If `:argument` is passed, then the session is expected
    #   to be in the argument list labeled as `:argument` by Dreck.
    # @return [void]
    # @note {#slop} and {#dreck} should be called before this, depending on whether
    #   options or arguments are being tested for a valid session.
    def ensure_session!(where = :option)
      label = where == :option ? @opts[:session] : @args[:session]
      @session = Session[label]
    end

    # Ensure that a record type passed in as an option or argument is resolvable
    #   to a record class.
    # @param where [Symbol] Where to look for the record type to test.
    #   If `:option` is passed, then the type is expected to be the value of the
    #   `--type` option. If `:argument` is passed, then the type is expected to
    #   be in the argument list labeled as `:type` by Dreck.
    # @return [void]
    # @note {#slop} and {#dreck} should be called before this, depending on whether
    #   options or arguments are being tested for a valid session.
    def ensure_type!(where = :option)
      type = TYPE_ALIASES[where == :option ? @opts[:type] : @args[:type]]
      Record.class_for type
    end

    # Ensure that a generator profile passed in as an option or argument already
    #   exists (i.e., is already configured).
    # @param where [Symbol] Where to look for the session label to test.
    #   If `:option` is passed, then the generator is expected to be the value of
    #   the `--generator` option. If `:argument` is passed, then the type is expected
    #   to be in the argument list labeled as `:generator` by Dreck.
    # @return [void]
    # @note {#slop} and {#dreck} should be called before this, depending on whether
    #   options or arguments are being tested for a valid session.
    def ensure_generator!(where = :option)
      gen = where == :option ? @opts[:generator] : @args[:generator]
      Config.generator gen
    end

    # "Guard" a block by propagating any exceptions as fatal (unrecoverable)
    #   errors.
    # @return [Object] the result of the block
    # @note This should be used to guard chunks of code that are likely to
    #   raise exceptions. The amount of code guarded should be minimized.
    def guard
      yield
    rescue => e
      stderr.puts e.backtrace if @opts&.debug?
      die "#{e.to_s.capitalize}."
    end

    # Prompt the user for some input.
    # @param question [String] the question to ask the user
    # @param echo [Boolean] whether or not to echo the user's input
    # @return [String] the user's response, with trailing newline removed
    def prompt(question, echo: true)
      if !echo && stdin.tty?
        stdin.getpass("#{question} ")
      else
        stdout.print "#{question} "
        stdin.gets.chomp
      end
    end

    # Print an informational message.
    # @param msg [String] the message to print
    # @return [void]
    def info(msg)
      info = ENV["NO_COLOR"] ? "Info" : GREEN["Info"]
      stderr.puts "#{info}: #{msg}"
    end

    # Print an information message, but only if verbose output has been enabled.
    # @param msg [String] the message to print
    # @return [void]
    def verbose(msg)
      return unless @opts.verbose?
      info msg
    end

    # Print an informational message via {#info} and exit successfully.
    # @param msg [String] the message to print
    # @return [void]
    # @note This method does not return!
    def bye(msg)
      info msg
      exit
    end

    # Print a warning message unless warnings have been suppressed.
    # @param msg [String] the message to print
    # @return [void]
    def warn(msg)
      return if @opts.no_warn?
      warning = ENV["NO_COLOR"] ? "Warning" : YELLOW["Warning"]
      stderr.puts "#{warning}: #{msg}"
    end
  end
end
