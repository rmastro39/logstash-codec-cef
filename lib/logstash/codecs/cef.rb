# encoding: utf-8
require "logstash/codecs/base"
require "json"

class LogStash::Codecs::CEF < LogStash::Codecs::Base
  # Implementation of a Logstash codec for the ArcSight Common Event Format (CEF)
  # Based on Revision 20 of Implementing ArcSight CEF, dated from June 05, 2013
  # https://protect724.hp.com/servlet/JiveServlet/downloadBody/1072-102-6-4697/CommonEventFormat.pdf
  config_name "cef"

  # Device vendor field in CEF header. The new value can include `%{foo}` strings
  # to help you build a new value from other parts of the event.
  config :vendor, :validate => :string, :default => "Elasticsearch"

  # Device product field in CEF header. The new value can include `%{foo}` strings
  # to help you build a new value from other parts of the event.
  config :product, :validate => :string, :default => "Logstash"

  # Device version field in CEF header. The new value can include `%{foo}` strings
  # to help you build a new value from other parts of the event.
  config :version, :validate => :string, :default => "1.0"

  # Signature ID field in CEF header. The new value can include `%{foo}` strings
  # to help you build a new value from other parts of the event.
  config :signature, :validate => :string, :default => "Logstash"

  # Name field in CEF header. The new value can include `%{foo}` strings
  # to help you build a new value from other parts of the event.
  config :name, :validate => :string, :default => "Logstash"

  # Severity field in CEF header. The new value can include `%{foo}` strings
  # to help you build a new value from other parts of the event.
  #
  # Defined as field of type string to allow sprintf. The value will be validated
  # to be an integer in the range from 0 to 10 (including).
  # All invalid values will be mapped to the default of 6.
  config :sev, :validate => :string, :default => "6"

  # Fields to be included in CEV extension part as key/value pairs
  config :fields, :validate => :array

  public
  def initialize(params={})
    super(params)
  end

  public
  def decode(data)
    # Strip any quotations at the start and end, flex connectors seem to send this
    if data[0] == "\""
      data = data[1..-2]
    end
    event = LogStash::Event.new

    # Split by the pipes
    event['cef_version'], event['cef_vendor'], event['cef_product'], event['cef_device_version'], event['cef_sigid'], event['cef_name'], event['cef_severity'], message = data.split /(?<!\\)[\|]/

    # Try and parse out the syslog header if there is one
    if event['cef_version'].include? ' '
      event['syslog'], unused, event['cef_version'] = event['cef_version'].rpartition(' ')
    end

    # Get rid of the CEF bit in the version
    event['cef_version'].sub! /^CEF:/, ''

    # Strip any whitespace from the message
    if not message.nil? and message.include? '='
      message = message.strip

      # If the last KVP has no value, add an empty string, this prevents hash errors below
      if message.end_with?("=")
        message=message + ' '
      end

      # Now parse the key value pairs into it
      extensions = {}
      message = message.split(/ ([\w\.]+)=/)
      key, value = message.shift.split('=', 2)
      extensions[key] = value

      Hash[*message].each{ |k, v| extensions[k] = v }

      # And save the new has as the extensions
      event['cef_ext'] = extensions
    end

    yield event
  end

  public
  def encode(event)
    # "CEF:0|Elasticsearch|Logstash|1.0|Signature|Name|Sev|"

    vendor = sanitize_header_field(event.sprintf(@vendor))
    vendor = self.class.get_config["vendor"][:default] if vendor == ""

    product = sanitize_header_field(event.sprintf(@product))
    product = self.class.get_config["product"][:default] if product == ""

    version = sanitize_header_field(event.sprintf(@version))
    version = self.class.get_config["version"][:default] if version == ""

    signature = sanitize_header_field(event.sprintf(@signature))
    signature = self.class.get_config["signature"][:default] if signature == ""

    name = sanitize_header_field(event.sprintf(@name))
    name = self.class.get_config["name"][:default] if name == ""

    sev = sanitize_header_field(event.sprintf(@sev)).strip
    sev = self.class.get_config["sev"][:default] unless valid_sev?(sev)
    sev = sev.to_i.to_s

    # Should also probably set the fields sent
    header = ["CEF:0", vendor, product, version, signature, name, sev].join("|")
    values = @fields.map {|fieldname| get_value(fieldname, event)}.compact.join(" ") unless fields.nil?

    @on_event.call(event, header + "|" + values.to_s + "\n")
  end

  # Escape pipes and backslashes in the header. Equal signs are ok.
  # Newlines are forbidden.
  def sanitize_header_field(value)
    output = ""

    value = value.gsub(/\r\n/, "\n")

    value.each_char{|c|
      case c
      when "\\", "|"
        output += "\\" + c
      when "\n", "\r"
        output += " "
      else
        output += c
      end
    }

    return output
  end

  # Keys must be made up of a single word, with no spaces
  # must be alphanumeric
  def sanitize_extension_key(value)
    value = value.gsub(/[^a-zA-Z0-9]/, "")
    return value
  end

  # Escape equal signs in the extensions. Canonicalize newlines.
  # CEF spec leaves it up to us to choose \r or \n for newline.
  # We choose \n as the default.
  def sanitize_extension_val(value)
    output = ""

    value = value.gsub(/\r\n/, "\n")

    value.each_char{|c|
      case c
      when "\\", "="
        output += "\\" + c
      when "\n", "\r"
        output += "\\n"
      else
        output += c
      end
    }

    return output
  end

  private

  def get_value(fieldname, event)
    val = event[fieldname]

    return nil if val.nil?

    case val
    when Array
      return sanitize_extension_key(fieldname) + "=" + sanitize_extension_val(val.to_json)
    when Hash
      return sanitize_extension_key(fieldname) + "=" + sanitize_extension_val(val.to_json)
    else
      return sanitize_extension_key(fieldname) + "=" + sanitize_extension_val(val)
    end
  end

  def valid_sev?(sev)
    return sev != "" && (sev.to_i.to_s == sev || sev.to_f.to_s == sev) && sev.to_i > 0 && sev.to_i < 10
  end

end
