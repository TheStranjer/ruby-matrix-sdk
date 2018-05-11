require 'matrix_sdk'

module MatrixSdk
  # A class for tracking the information about a room on Matrix
  class Room
    # @!attribute [rw] canonical_alias
    #   @return [String, nil] the canonical alias of the room
    # @!attribute [rw] event_history_limit
    #   @return [Fixnum] the limit of events to keep in the event log
    attr_accessor :canonical_alias, :event_history_limit
    # @!attribute [r] id
    #   @return [String] the internal ID of the room
    # @!attribute [r] client
    #   @return [Client] the client for the room
    # @!attribute [rw] name
    #   @return [String, nil] the user-provided name of the room
    #   @see reload_name!
    # @!attribute [rw] topic
    #   @return [String, nil] the user-provided topic of the room
    #   @see reload_topic!
    # @!attribute [r] aliases
    #   @return [Array(String)] a list of user-set aliases for the room
    #   @see add_alias
    #   @see reload_alias!
    # @!attribute [rw] join_rule
    #   @return [:invite, :public] the join rule for the room -
    #                    either +:invite+ or +:public+
    # @!attribute [rw] guest_access
    #   @return [:can_join, :forbidden] the guest access for the room -
    #                    either +:can_join+ or +:forbidden+
    # @!attribute [r] members
    #   @return [Array(User)] the members of the room
    #   @see reload_members!
    # @!attribute [r] events
    #   @return [Array(Object)] the last +event_history_limit+ events to arrive in the room
    #   @see https://matrix.org/docs/spec/client_server/r0.3.0.html#get-matrix-client-r0-sync
    #        The timeline events are what will end up in here
    attr_reader :id, :client, :name, :topic, :aliases, :join_rule, :guest_access, :members, :events

    # @!attribute [r] on_event
    #   @return [EventHandlerArray] The list of event handlers for all events
    # @!attribute [r] on_state_event
    #   @return [EventHandlerArray] The list of event handlers for only state events
    # @!attribute [r] on_ephemeral_event
    #   @return [EventHandlerArray] The list of event handlers for only ephemeral events
    events :event, :state_event, :ephemeral_event
    # @!method inspect
    #   An inspect method that skips a handful of instance variables to avoid
    #   flooding the terminal with debug data.
    #   @return [String] a regular inspect string without the data for some variables
    ignore_inspect :client, :members, :events, :prev_batch,
                   :on_event, :on_state_event, :on_ephemeral_event

    alias room_id id

    def initialize(client, room_id, data = {})
      event_initialize
      @client = client
      @id = room_id.to_s

      @name = nil
      @topic = nil
      @canonical_alias = nil
      @aliases = []
      @join_rule = nil
      @guest_access = nil
      @members = []
      @events = []
      @event_history_limit = 10

      @prev_batch = nil

      data.each do |k, v|
        instance_variable_set("@#{k}", v) if instance_variable_defined? "@#{k}"
      end

      logger.debug "Created room #{room_id}"
    end

    def logger
      Logging.logger[self.class.name]
    end

    #
    # State readers
    #

    # Gets a human-readable name for the room
    #
    # This will return #name or #canonical_alias if they've been set,
    # otherwise it will query the API for members and generate a string from
    # a subset of their names.
    #
    # @return [String] a human-readable name for the room
    # @note This method will populate the #members list if it has to fall back
    #       to the member name generation.
    def display_name
      return name if name
      return canonical_alias if canonical_alias

      members = joined_members
                .reject { |m| m.user_id == client.mxid }
                .map(&:get_display_name)

      return members.first if members.one?
      return "#{members.first} and #{members.last}" if members.count == 2
      return "#{members.first} and #{members.count - 1} others" if members.count > 2

      'Empty Room'
    end

    # Populates and returns the #members array
    def joined_members
      return members unless members.empty?

      client.api.get_room_members(id)[:chunk].each do |chunk|
        next unless chunk [:content][:membership] == 'join'
        ensure_member(User.new(client, chunk[:state_key], display_name: chunk[:content].fetch(:displayname)))
      end
      members
    end

    # Checks if +guest_access+ is set to +:can_join+
    def guest_access?
      guest_access == :can_join
    end

    # Checks if +join_rule+ is set to +:invite+
    def invite_only?
      join_rule == :invite
    end

    #
    # Message handling
    #

    # Sends a plain-text message to the room
    # @param text [String] the message to send
    def send_text(text)
      client.api.send_message(id, text)
    end

    # Sends a custom HTML message to the room
    # @param html [String] the HTML message to send
    # @param body [String,nil] a plain-text representation of the object
    #        (Will default to the HTML with tags stripped away)
    # @param msg_type [String] A message type for the message
    # @see https://matrix.org/docs/spec/client_server/r0.3.0.html#m-room-message-msgtypes
    #      Possible message types as defined by the spec
    def send_html(html, body = nil, msg_type = 'm.text')
      content = {
        body: body ? body : html.gsub(/<\/?[^>]*>/, ''),
        msgtype: msg_type,
        format: 'org.matrix.custom.html',
        formatted_body: html
      }

      client.api.send_message_event(id, 'm.room.message', content)
    end

    # Sends an emote (/me) message to the room
    # @param text [String] the emote to send
    def send_emote(text)
      client.api.send_emote(id, text)
    end

    def send_file(url, name, file_info = {})
      client.api.send_content(id, url, name, 'm.file', extra_information: file_info)
    end

    def send_notice(text)
      client.api.send_notice(id, text)
    end

    def send_image(url, name, image_info = {})
      client.api.send_content(id, url, name, 'm.image', extra_information: image_info)
    end

    def send_location(geo_uri, name, thumbnail_url = nil, thumbnail_info = {})
      client.api.send_location(id, geo_uri, name, thumbnail_url: thumbnail_url, thumbnail_info: thumbnail_info)
    end

    def send_video(url, name, video_info = {})
      client.api.send_content(id, url, name, 'm.video', extra_information: video_info)
    end

    def send_audio(url, name, audio_info = {})
      client.api.send_content(id, url, name, 'm.audio', extra_information: audio_info)
    end

    def redact_message(event_id, reason = nil)
      client.api.redact_event(id, event_id, reason: reason)
    end

    def backfill_messages(reverse = false, limit = 10)
      data = client.api.get_room_messages(id, @prev_batch, direction: :b, limit: limit)

      events = data[:chunk]
      events.reverse! unless reverse
      events.each do |ev|
        put_event(ev)
      end
    end

    #
    # User Management
    #

    def invite_user(user_id)
      client.api.invite_user(id, user_id)
      true
    rescue MatrixError
      false
    end

    def kick_user(user_id, reason = '')
      client.api.kick_user(id, user_id, reason: reason)
      true
    rescue MatrixError
      false
    end

    def ban_user(user_id, reason = '')
      client.api.ban_user(id, user_id, reason: reason)
      true
    rescue MatrixError
      false
    end

    def unban_user(user_id)
      client.api.unban_user(id, user_id)
      true
    rescue MatrixError
      false
    end

    def leave
      client.api.leave_room(id)
      client.rooms.delete id
      true
    rescue MatrixError
      false
    end

    def get_account_data(type)
      client.api.get_room_account_data(client.mxid, id, type)
    end

    def set_account_data(type, account_data)
      client.api.set_room_account_data(client.mxid, id, type, account_data)
    end

    def set_user_profile(params = {})
      return nil unless params[:display_name] || params[:avatar_url]
      data = client.api.get_membership(id, client.mxid)
      raise "Can't set profile if you haven't joined the room" unless data[:membership] == 'join'

      data[:displayname] = params[:display_name] unless params[:display_name].nil?
      data[:avatar_url] = params[:avatar_url] unless params[:avatar_url].nil?

      client.api.set_membership(id, client.mxid, 'join', params.fetch(:reason, 'Updating room profile information'), data)
    end

    def tags
      client.api.get_user_tags(client.mxid, id)
    end

    def remove_tag(tag)
      client.api.remove_user_tag(client.mxid, id, tag)
    end

    def add_tag(tag, params = {})
      client.api.add_user_tag(client.mxid, id, tag, params)
    end

    #
    # State updates
    #

    def name=(name)
      client.api.set_room_name(id, name)
      @name = name
    rescue MatrixError
      nil
    end

    def reload_name!
      data = client.api.get_room_name(id)
      changed = data[:name] != name
      @name = data[:name] if changed
      changed
    rescue MatrixError
      false
    end

    def topic=(topic)
      client.api.set_room_topic(id, topic)
      @topic = topic
    rescue MatrixError
      nil
    end

    def reload_topic!
      data = client.api.get_room_topic(id)
      changed = data[:topic] != topic
      @topic = data[:topic] if changed
      changed
    rescue MatrixError
      false
    end

    # Add an alias to the room
    # @return [Boolean] if the addition was successful or not
    def add_alias(room_alias)
      client.api.set_room_alias(id, room_alias)
      @aliases << room_alias
      true
    rescue MatrixError
      false
    end

    # Reloads the list of aliases by an API query
    # @return [Boolean] if the alias list was updated or not
    # @note The list of aliases is not sorted, ordering changes will result in
    #       alias list updates.
    def reload_aliases!
      data = client.api.get_room_state(id)
      new_aliases = data.select { |chunk| chunk.key?(:content) && chunk[:content].key?(:aliases) }
                        .map { |chunk| chunk[:content][:aliases] }
                        .flatten
                        .reject(&:nil?)
      return false if new_aliases.nil?

      changed = new_aliases != aliases
      @aliases = new_aliases if changed
      changed
    rescue MatrixError
      false
    end

    def invite_only=(invite_only)
      self.join_rule = invite_only ? :invite : :public
      @join_rule == :invite # rubocop:disable Lint/Void
    end

    def join_rule=(join_rule)
      client.api.set_join_rule(id, join_rule)
      @join_rule = join_rule
    rescue MatrixError
      nil
    end

    def allow_guests=(allow_guests)
      self.guest_access = (allow_guests ? :can_join : :forbidden)
      @guest_access == :can_join # rubocop:disable Lint/Void
    end

    def guest_access=(guest_access)
      client.api.set_guest_access(id, guest_access)
      @guest_access = guest_access
    rescue MatrixError
      nil
    end

    def modify_user_power_levels(users = nil, users_default = nil)
      return false if users.nil? && users_default.nil?
      data = client.api.get_power_levels(id)
      data[:users_default] = users_default unless users_default.nil?

      if users
        data[:users] = {} unless data.key? :users
        data[:users].merge!(users)
        data[:users].delete_if { |_k, v| v.nil? }
      end

      client.api.set_power_levels(id, data)
      true
    rescue MatrixError
      false
    end

    def modify_required_power_levels(events = nil, params = {})
      return false if events.nil? && (params.nil? || params.empty?)
      data = client.api.get_power_levels(id)
      data.merge!(params)
      data.delete_if { |_k, v| v.nil? }

      if events
        data[:events] = {} unless data.key? :events
        data[:events].merge!(events)
        data[:events].delete_if { |_k, v| v.nil? }
      end

      client.api.set_power.levels(id, data)
    rescue MatrixError
      false
    end

    private

    def ensure_member(member)
      members << member unless members.any? { |m| m.id == member.id }
    end

    def put_event(event)
      @events.push event
      @events.shift if @events.length > @event_history_limit

      fire_event MatrixEvent.new(self, event)
    end

    def put_ephemeral_event(event)
      fire_ephemeral_event MatrixEvent.new(self, event)
    end
  end
end
