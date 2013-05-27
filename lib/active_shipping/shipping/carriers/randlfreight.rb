module ActiveMerchant
  module Shipping
    
    # :key is your developer API key

    class RAndLFreight < Carrier
      self.retry_safe = true
      
      cattr_reader :name
      @@name = "R+L Freight"
      
      TEST_URL = 'http://api.rlcarriers.com/1.0.1/RateQuoteService.asmx '
      LIVE_URL = 'http://api.rlcarriers.com/1.0.1/RateQuoteService.asmx '

      QuoteTypes = {
          "alaska_hawaii" => "AlaskaHawaii",
          "domestic" => "Domestic",
          "international" => "International"
      }

      Accessorials = {
        "inside_delivery" => "InsideDelivery",
        "residential_pickup" => "ResidentialPickup",
        "residential_delivery" => "ResidentialDelivery",
        "origin_liftgate" => "OriginLiftgate",
        "destination_liftgate" => "DestinationLiftgate",
        "delivery_notification" => "DeliveryNotification",
        "freezable" => "Freezable",
        "hazmat" => "Hazmat",
        "inside_pickup" => "InsidePickup",
        "limited_access_pickup" => "LimitedAccessPickup",
        "dock_pickup" => "DockPickup",
        "dock_delivery" => "DockDelivery",
        "airport_pickup" => "AirportPickup",
        "airport_delivery" => "AirportDelivery",
        "limited_access_delivery" => "LimitedAccessDelivery",
        "cubic_feet" => "CubicFeet",
        "keep_from_freezing" => "KeepFromFreezing",
        "door_to_door" => "DoorToDoor",
        "cod" => "COD",
        "fz" => "FZ",
        "over_dimension" => "OverDimension",
        "airport_delivery" => "AirportDelivery",
        "limited_access_delivery" => "LimitedAccessDelivery"
      }

      def requirements
        [:key]
      end

      def maximum_weight
        Mass.new(1000000, :pounds)    # Make an arbitrarily large number; there really isn't a limit
      end

      def find_rates(origin, destination, packages, options = {})
        options = @options.update(options)
        packages = Array(packages)
        
        rate_request = build_rate_request(origin, destination, packages, options)
        
        response = commit(save_request(rate_request), (options[:test] || false)).gsub(/<\/?soap:.*?>/,'')
        
        parse_rate_response(origin, destination, packages, response, options)
      end


      protected
      def build_rate_request(origin, destination, packages, options={})
        imperial = ['US','LR','MM'].include?(origin.country_code(:alpha2))

        xml_request = XmlNode.new('soap12:Envelope', 'xmlns:soap12' => 'http://www.w3.org/2003/05/soap-envelope') do |soapenv|
          soapenv << XmlNode.new('soap12:Body') do |grq|
            grq << XmlNode.new('rlc:GetRateQuote', 'xmlns:rlc' => 'http://www.rlcarriers.com/') do |root_node|


          root_node << XmlNode.new('rlc:APIKey', @options[:key])            #required

          root_node << XmlNode.new('rlc:request') do |rs|
            rs << XmlNode.new('rlc:CustomerData', 'ShipHawk.com')           #optional
            rs << XmlNode.new('rlc:QuoteType', QuoteTypes['domestic'])      #required
            rs << XmlNode.new('rlc:CODAmount', '0')                         #required
            rs << build_location_node('rlc:Origin', origin)
            rs << build_location_node('rlc:Destination', destination)
            rs << XmlNode.new('rlc:Items') do |item|                        #required - one to eight items
              packages.each do |pkg|
                item << XmlNode.new('rlc:Item')  do |itemd|                 #required
                itemd << XmlNode.new('rlc:Class', pkg.options[:freight_class])        #optional           #need to pull these from options instead of hard code
                itemd << XmlNode.new('rlc:Weight', pkg.lbs)                 #required
                itemd << XmlNode.new('rlc:Width', pkg.inches(:width))       #required
                itemd << XmlNode.new('rlc:Height', pkg.inches(:height))     #required
                itemd << XmlNode.new('rlc:Length', pkg.inches(:length))     #required
                end
              end
            end
            rs << XmlNode.new('rlc:DeclaredValue', options[:value])         #required
            rs << XmlNode.new('rlc:Accessorials') do |ac|                   #optional
              ac << XmlNode.new('rlc:Accessorial', Accessorials['residential_delivery']) if options[:residential]
              ac << XmlNode.new('rlc:Accessorial', Accessorials['destination_liftgate']) if options[:liftgate]
             ac << XmlNode.new('rlc:Accessorial', Accessorials['delivery_notification']) if options[:delivery_notification]

            end

            rs << XmlNode.new('OverDimensionPcs', '0')                      #required
          end
            end
          end
        end
        xml_request.to_xml
      end
      
      def build_location_node(name, location)
        location_node = XmlNode.new(name) do |xml_node|
          xml_node << XmlNode.new('rlc:City', location.city)                #optional
          xml_node << XmlNode.new('rlc:StateOrProvince', location.province) #optional
          xml_node << XmlNode.new('rlc:ZipOrPostalCode', location.postal_code)  #optional
          xml_node << XmlNode.new('rlc:CountryCode', 'USA')                 #required (despite what wsdl says)
          end
        end

      def parse_rate_response(origin, destination, packages, response, options)
        rate_estimates = []
        messages = []
        success, message = nil
        
        xml = REXML::Document.new(response)
        root_node = xml.elements['GetRateQuoteResponse/GetRateQuoteResult']
        
        success = root_node.elements['WasSuccess'].text.to_bool

        #Messages at this level are returned if invalid data is passed to the API; these are not messages for the user
        #Returned as an array of <string> elements
        #Example: <string>Origin Country must be USA or CAN for Quote Type: Domestic. Please use either AlaskaHawaii or International.</string>
        #         <string>Destination Country must be USA or CAN for Quote Type: Domestic. Please use either AlaskaHawaii or International.</string>
        message = root_node.elements.each('Messages/string/text()') {|el| el}.join(', ')

        service_levels =  root_node.elements.each('Result/ServiceLevels/ServiceLevel') do |service_level|
          service_name = service_level.text('Title')
          service_code = service_level.text('Code')
          rate_estimates << RateEstimate.new(origin, destination, @@name,
             service_name,
             :service_code => service_code,
             :total_price => service_level.text('NetCharge').sub('$','').sub(',','').to_f,     # active shipping returns this in cents
             :currency => 'USD',
             :packages => packages,
             :delivery_range => [Date.today + service_level.get_text('ServiceDays').to_s.to_i] * 2)    #delivery_range is an array of dates; R+L does not return a delivery date, only "Service Days"; need to update to business days
        end


        if rate_estimates.empty?
          success = false
          message = "No shipping rates could be found for the destination address" if message.blank?
        end

        RateResponse.new(success, message, Hash.from_xml(response), :rates => rate_estimates, :xml => response, :request => last_request, :log_xml => options[:log_xml])
      end

      def commit(request, test = false)
        ssl_post(test ? TEST_URL : LIVE_URL, request.gsub("\n",''), {"Content-Type" => "application/soap+xml; charset=utf-8; action='http://www.rlcarriers.com/GetRateQuote'"})
      end

  end

  end

end

#Should move this to another location that makes more sense and it's accessible from anywhere.
class String
  def to_bool
    return true if self == true || self =~ (/^(true|t|yes|y|1)$/i)
    return false if self == false || self.blank? || self =~ (/^(false|f|no|n|0)$/i)
    raise ArgumentError.new("invalid value for Boolean: \"#{self}\"")
  end

end