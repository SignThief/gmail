module Gmail
  module Client
    class Base
      # Gmail IMAP defaults
      GMAIL_IMAP_HOST = 'imap.gmail.com'.freeze
      GMAIL_IMAP_PORT = 993

      # Gmail SMTP defaults
      GMAIL_SMTP_HOST = "smtp.gmail.com".freeze
      GMAIL_SMTP_PORT = 587

      attr_reader :username
      attr_reader :options

      def initialize(username, options = {})
        defaults       = {}
        @username      = fill_username(username)
        @options       = defaults.merge(options)
        @mailbox_mutex = Mutex.new
      end

      # Connect to gmail service.
      def connect(raise_errors = false)
        @imap = Net::IMAP.new(GMAIL_IMAP_HOST, GMAIL_IMAP_PORT, true, nil, false)
        @imap
      rescue SocketError
        raise_errors and raise ConnectionError, "Couldn't establish connection with Gmail IMAP service"
      end

      # This version of connect will raise error on failure...
      def connect!
        connect(true)
      end

      # Return current connection. Log in automaticaly to specified account if
      # it is necessary.
      def connection
        login and at_exit { logout } unless logged_in?
        @imap
      end
      alias :conn :connection

      # Login to specified account.
      def login(*args)
        raise NotImplementedError, "The `#{self.class.name}#login` method is not implemented."
      end
      alias :sign_in :login

      # This version of login will raise error on failure...
      def login!
        login(true)
      end
      alias :sign_in! :login!

      # Returns +true+ when you are logged in to specified account.
      def logged_in?
        !!@logged_in
      end
      alias :signed_in? :logged_in?

      # Logout from Gmail service.
      def logout
        @imap && logged_in? and @imap.logout
      ensure
        @logged_in = false
      end
      alias :sign_out :logout

      # Disconnect from Gmail service.
      def disconnect
        @imap && @imap.disconnect
      end

      # Return labels object, which helps you with managing your Gmail labels.
      # See <tt>Gmail::Labels</tt> for details.
      def labels
        @labels ||= Labels.new(conn)
      end

      # Compose new e-mail.
      #
      # ==== Examples
      #
      #   mail = gmail.compose
      #   mail.from "test@gmail.org"
      #   mail.to "friend@gmail.com"
      #
      # ... or block style:
      #
      #   mail = gmail.compose do
      #     from "test@gmail.org"
      #     to "friend@gmail.com"
      #     subject "Hello!"
      #     body "Hello my friend! long time..."
      #   end
      #
      # Now you can deliver your mail:
      #
      #   gmail.deliver(mail)
      def compose(mail = nil, &block)
        if block_given?
          mail = Mail.new(&block)
        elsif !mail
          mail = Mail.new
        end

        mail.delivery_method(*smtp_settings)
        mail.from = username unless mail.from
        mail
      end
      alias :message :compose

      # Compose (optionaly) and send given email.
      #
      # ==== Examples
      #
      #   gmail.deliver do
      #     to "friend@gmail.com"
      #     subject "Hello friend!"
      #     body "Hi! How are you?"
      #   end
      #
      # ... or with already created message:
      #
      #   mail = Mail.new { ... }
      #   gmail.deliver(mail)
      #
      #   mail = gmail.compose { ... }
      #   gmail.deliver(mail)
      def deliver(mail = nil, raise_errors = false, &block)
        mail = compose(mail, &block)
        mail.deliver!
      rescue Object => ex
        raise_errors and raise DeliveryError, "Couldn't deliver email: #{ex.to_s}"
      end

      # This version of deliver will raise error on failure...
      def deliver!(mail = nil, &block)
        deliver(mail, true, &block)
      end

      # Do something with given mailbox or within it context.
      #
      # ==== Examples
      #
      #   mailbox = gmail.mailbox("INBOX")
      #   mailbox.emails(:all)
      #   mailbox.count(:unread, :before => Time.now-(20*24*3600))
      #
      # ... or block style:
      #
      #   gmail.label("Work") do |mailbox|
      #     mailbox.emails(:unread)
      #     mailbox.count(:all)
      #     ...
      #   end
      def mailbox(name, &block)
        @mailbox_mutex.synchronize do
          name = labels.localize(name)
          mailbox = (mailboxes[name] ||= Mailbox.new(self, name))
          switch_to_mailbox(mailbox) if @current_mailbox != mailbox

          if block_given?
            mailbox_stack << @current_mailbox
            result = block.arity == 1 ? yield(mailbox) : yield
            mailbox_stack.pop
            switch_to_mailbox(mailbox_stack.last)
            return result
          end

          return mailbox
        end
      end
      alias :in_mailbox :mailbox
      alias :in_label :mailbox
      alias :label :mailbox

      # Alias for <tt>mailbox("INBOX")</tt>. See <tt>Gmail::Mailbox</tt>
      # for details.
      def inbox
        mailbox("INBOX")
      end

      # Functionality like rails #find method
      # https://support.google.com/mail/answer/7190?hl=en
      # Messages with a certain message-id header
      # Rfc822msgid:
      # Example: rfc822msgid:200503292@example.com
      def find(rfc822msgid)
        message = :message_before_built

        mailbox(:all) do |mailbox|
          uid = conn.uid_search(['X-GM-RAW', "rfc822msgid:#{rfc822msgid.to_s.strip}"]).first
          raise EmailNotFound, "Can't find message with ID #{rfc822msgid}" unless uid
          message = Message.new(mailbox, uid)
        end

        message
      end

      def mailboxes
        @mailboxes ||= {}
      end

      def inspect
        "#<Gmail::Client#{'0x%04x' % (object_id << 1)} (#{username}) #{'dis' if !logged_in?}connected>"
      end

      def fill_username(username)
        username =~ /@/ ? username : "#{username}@gmail.com"
      end

      def mail_domain
        username.split('@').last
      end

      private

      def switch_to_mailbox(mailbox)
        if mailbox
          conn.select(mailbox.encoded_name)
        end
        @current_mailbox = mailbox
      end

      def mailbox_stack
        @mailbox_stack ||= []
      end

      def smtp_settings
        [:smtp, {
          :address => GMAIL_SMTP_HOST,
          :port => GMAIL_SMTP_PORT,
          :domain => mail_domain,
          :user_name => username,
          :password => password,
          :authentication => 'plain',
          :enable_starttls_auto => true
        }]
      end
    end # Base
  end # Client
end # Gmail
