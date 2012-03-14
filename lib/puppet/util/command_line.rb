require 'puppet'
require "puppet/util/plugins"
require 'puppet/util/command_line_utils/puppet_option_parser'

module Puppet
  module Util
    class CommandLine

      # Just aliasing in the class name for brevity
      PuppetOptionParser = Puppet::Util::CommandLineUtils::PuppetOptionParser

      def initialize(zero = $0, argv = ARGV, stdin = STDIN)
        @zero  = zero
        @argv  = argv.dup
        @stdin = stdin

        @subcommand_name, @args = subcommand_and_args(@zero, @argv, @stdin)
        Puppet::Plugins.on_commandline_initialization(:command_line_object => self)
      end

      attr :subcommand_name
      attr :args

      def appdir
        File.join('puppet', 'application')
      end

      # TODO cprice: document
      def parse_global_options
        # Create an option parser
        #option_parser = OptionParser.new
        option_parser = PuppetOptionParser.new
        option_parser.ignore_invalid_options = true

        # Add all global options to it.
        Puppet.settings.optparse_addargs([]).each do |option|
          option_parser.on(*option) do |arg|
            handlearg(option[0], arg)

          end
        end

        option_parser.parse(args)

      end
      private :parse_global_options


      # TODO cprice: document
      def handlearg(opt, val)
        #puts("HANDLE ARG: '#{opt}'")
        opt, val = self.class.clean_opt(opt, val)
        Puppet.settings.handlearg(opt, val)
      end
      private :handlearg

      # TODO cprice: document
      def self.clean_opt(opt, val)
        # rewrite --[no-]option to --no-option if that's what was given
        if opt =~ /\[no-\]/ and !val
          opt = opt.gsub(/\[no-\]/,'no-')
        end
        # otherwise remove the [no-] prefix to not confuse everybody
        opt = opt.gsub(/\[no-\]/, '')
        [opt, val]
      end



      def self.available_subcommands
        # TODO cprice: eventually we probably want to replace this with a call to the autoloader.  however, at the moment
        #  the autoloader considers the module path when loading, and we don't want to allow apps / faces to load
        #  from there.  Once that is resolved, this should be replaced.  --cprice 2012-03-06
        absolute_appdirs = $LOAD_PATH.collect do |x|
          File.join(x,'puppet','application')
        end.select{ |x| File.directory?(x) }
        absolute_appdirs.inject([]) do |commands, dir|
          commands + Dir[File.join(dir, '*.rb')].map{|fn| File.basename(fn, '.rb')}
        end.uniq
      end
      # available_subcommands was previously an instance method, not a class
      # method, and we have an unknown number of user-implemented applications
      # that depend on that behaviour.  Forwarding allows us to preserve a
      # backward compatible API. --daniel 2011-04-11
      def available_subcommands
        self.class.available_subcommands
      end

      def require_application(application)
        require File.join(appdir, application)
      end

      def execute
        # TODO cprice: document, possibly refactor into some kind of setup/init method
        Puppet::Util.exit_on_fail("parse global options")     { parse_global_options }
        # NOTE: this is a change in behavior where we are now parsing the config file on every run; before, there
        #  were several apps that did not do this.
        Puppet::Util.exit_on_fail("parse configuration file") { Puppet.settings.parse }

        if subcommand_name and available_subcommands.include?(subcommand_name) then
          require_application subcommand_name
          # TODO cprice: replace this.  For the short term, replace it with something that is not so application-specific
          #  (i.e.. so that we can load faces).  Longer-term, use the autoloader.  See comments in
          #  #available_subcommands method above.  --cprice 2012-03-06
          app = Puppet::Application.find(subcommand_name).new(self)
          Puppet::Plugins.on_application_initialization(:appliation_object => self)

          # See the note in 'warn_later' down below. --daniel 2011-06-01
          if $delayed_deprecation_warning_for_p_u_cl.is_a? String then
            Puppet.deprecation_warning($delayed_deprecation_warning_for_p_u_cl)
            $delayed_deprecation_warning_for_p_u_cl = true
          end

          app.run
        elsif ! execute_external_subcommand then
          unless subcommand_name.nil? then
            puts "Error: Unknown Puppet subcommand '#{subcommand_name}'"
          end
          puts "See 'puppet help' for help on available puppet subcommands"
        end
      end

      def execute_external_subcommand
        external_command = "puppet-#{subcommand_name}"

        require 'puppet/util'
        path_to_subcommand = Puppet::Util.which(external_command)
        return false unless path_to_subcommand

        exec(path_to_subcommand, *args)
      end

      def legacy_executable_name
        name = CommandLineUtils::LegacyCommandLine::LEGACY_NAMES[ subcommand_name.intern ]
        return name unless name.nil?
        return subcommand_name.intern
      end

      private

      def subcommand_and_args(zero, argv, stdin)
        zero = File.basename(zero, '.rb')

        if zero == 'puppet'
          case argv.first
          when nil then
            if stdin.tty? then
              [nil, argv]       # ttys get usage info
            else
              # Killed for 2.7.0 --daniel 2011-06-01
              warn_later <<EOM
Implicit invocation of 'puppet apply' by redirection into 'puppet' is deprecated,
and will be removed in the 2.8 series. Please invoke 'puppet apply' directly
in the future.
EOM
              ["apply", argv]
            end
          when "--help", "-h" then
            # help should give you usage, not the help for `puppet apply`
            [nil, argv]
          when /^-|\.pp$|\.rb$/ then
            # Killed for 2.7.0 --daniel 2011-06-01
            warn_later <<EOM
Implicit invocation of 'puppet apply' by passing files (or flags) directly
to 'puppet' is deprecated, and will be removed in the 2.8 series.  Please
invoke 'puppet apply' directly in the future.
EOM
            ["apply", argv]
          else
            [argv.first, argv[1..-1]]
          end
        else
          [zero, argv]
        end
      end


      ## TODO cprice: update this stuff

      # So, this is more than a little bit of a horror.  You see, the process
      # of bootstrapping Puppet is ... complex.  This file, like many of our
      # early initialization files, has an incestuous relationship between the
      # order of files loaded, code executed at load time, and code executed
      # in other files at runtime.
      #
      # When we construct this object we have not yet actually loaded the
      # global puppet object, so we can't use any methods in it.  That
      # includes all the logging stuff, which is used by the deprecation
      # warning subsystem.
      #
      # On the other hand, we can't just load the logging system, because that
      # depends on the top level Puppet module being bootstrapped.  It doesn't
      # actually load the stuff it uses, though, for hysterical raisins.
      #
      # Finally, we can't actually just load the top level Puppet module.
      # This one is precious: it turns out that some of the code loaded in the
      # top level Puppet module has a dependency on the run mode values.
      #
      # Run mode is set correctly *only* when the application is loaded, and
      # if it is wrong when the top level code is brought in we end up with
      # the wrong settings scattered through some of the defaults.
      #
      # Which means that we have a dependency cycle that runs:
      # 1. The binary creates an instance of P::U::CL.
      # 2. That identifies the application to load.
      # 3. It does, then instantiates the application.
      #    4. That sets the run-mode.
      #    5. That then loads the top level Puppet module.
      # 6. Finally, we get to where we can use the top level stuff
      #
      # So, essentially, we see a dependency between runtime code in this
      # file, run-time code in the application, and load-time code in the top
      # level module.
      #
      # Which leads me to our current horrible hack: we stash away the message
      # we wanted to log about deprecation, then send it to our logging system
      # once we have done enough bootstrapping that it will, y'know, actually
      # work.
      #
      # I would have liked to fix this, but that is going to be a whole pile
      # of work digging through and decrufting all the global state from the
      # local state, and working out what depends on what else in the product.
      #
      # Oh, and we use a global because we have *two* instances of a P::U::CL
      # object during the startup sequence.  I don't know why.
      #
      # Maybe, one day, when I am not behind a deadline to ship code.
      # --daniel 2011-06-01
      def warn_later(text)
        return if $delayed_deprecation_warning_for_p_u_cl
        $delayed_deprecation_warning_for_p_u_cl = text
      end
    end
  end
end
