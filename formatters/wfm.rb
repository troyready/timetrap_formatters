# Timetrap formatter to send entries to WorkflowMax.
# Current design makes the following workflow assumptions:
# 1) Each WFM task will represented by a single Timetrap sheet
# 2) All sheet entries for a given day will be combined into a single WFM
#    time entry.
#
# Setup:
# 1) Install the httparty and gyoku gems in your ruby environment
# 2) Add a wfm hash to your .timetrap.yml in the following form:
# wfm:
#   email: myuser@mycompany.org
#   apiKey: <apikeyhere>
#   accountKey: <accountkeyhere>
#   aliases:
#     myfirsttimesheet:
#       job: J000150
#       task: 39034523
#     mysecondtimesheet:
#       job: J000150
#       task: 39034523
#
# (job and task numbers can be retrieved from the WFM web site)
#
class Timetrap::Formatters::Wfm
  include Timetrap::Helpers

  DATE_FORMAT = '%Y%m%d'.freeze

  # Could be made into its own gem if useful elsewhere
  class Timetrap::Formatters::Wfm::WfmClient
    require 'date'
    require 'gyoku'
    require 'httparty'

    include HTTParty
    base_uri 'https://api.workflowmax.com'

    def initialize
      @options = {
        query: {
          'apiKey' => Timetrap::Config['wfm']['apiKey'],
          'accountKey' => Timetrap::Config['wfm']['accountKey']
        }
      }
    end

    def staff
      self.class.get(
        '/staff.api/list',
        @options
      )['Response']['StaffList']['Staff']
    end

    def current_time_entries(id, day)
      options = @options
      options[:query]['from'] = Date.parse(day).strftime(DATE_FORMAT)
      options[:query]['to'] = (Date.parse(day) + 1).strftime(DATE_FORMAT)
      self.class.get(
        "/time.api/staff/#{id}",
        options
      )['Response']['Times'] # either nil or entries in ['Time']
    end

    def add_time_entry(entry_params)
      options = @options
      options[:body] = Gyoku.xml(
        'Timesheet' => {
          'Job' => entry_params[:job],
          'Task' => entry_params[:task],
          'Staff' => entry_params[:staff],
          'Date' => entry_params[:date],
          'Minutes' => entry_params[:minutes],
          'Note' => entry_params[:note]
        }
      )
      self.class.post(
        '/time.api/add',
        options
      )
    end
  end

  def initialize(entries)
    @client = Timetrap::Formatters::Wfm::WfmClient.new
    entries = combine_entries(entries)
    @my_id = @client.staff.find { |s| s['Email'] == Timetrap::Config['wfm']['email'] }['ID']
    # Check with WFM and see if the entries have already been posted
    @entries = remove_days_already_submitted(entries)
  end

  def output
    if @entries == {}
      puts 'No new entries found to upload'
    else
      uploaded_minutes = 0
      puts 'Uploading new entries...'
      @entries.each do |sheet, days|
        days.each do |day, entry|
          entry_minutes = (entry['seconds'].to_f / 60).round
          uploaded_minutes += entry_minutes
          @client.add_time_entry(
            job: Timetrap::Config['wfm']['aliases'][sheet]['job'],
            task: Timetrap::Config['wfm']['aliases'][sheet]['task'],
            staff: @my_id,
            date: day,
            minutes: entry_minutes,
            note: entry['notes']
          )
        end
      end
    puts "Upload complete. #{uploaded_minutes} minutes "\
         "(#{(uploaded_minutes.to_f / 60).round(1)} hours) recorded."
    end
  end

  def combine_entries(entries)
    # We're only going to post a single entry to WFM for simplicity, so this
    # method will take each day's entries and combine them into one
    combined_entries = {}
    entries.each do |e|
      if combined_entries.key?(e.sheet) &&
         combined_entries[e.sheet][e.start.strftime(DATE_FORMAT)]
        combined_entries[e.sheet][e.start.strftime(DATE_FORMAT)]['seconds'] += e.duration
        if !["\n", ''].include? combined_entries[e.sheet][e.start.strftime(DATE_FORMAT)]['notes']
          combined_entries[e.sheet][e.start.strftime(DATE_FORMAT)]['notes'] = e.note
        else
          combined_entries[e.sheet][e.start.strftime(DATE_FORMAT)]['notes'] += "\n#{e.note}"
        end
      elsif combined_entries.key?(e.sheet)
        combined_entries[e.sheet][e.start.strftime(DATE_FORMAT)] = {}
        combined_entries[e.sheet][e.start.strftime(DATE_FORMAT)]['seconds'] = e.duration
        combined_entries[e.sheet][e.start.strftime(DATE_FORMAT)]['notes'] = e.note
      else
        combined_entries[e.sheet] = {
          e.start.strftime(DATE_FORMAT) => {
            'seconds' => e.duration,
            'notes' => e.note
          }
        }
      end
    end
    combined_entries
  end

  def remove_days_already_submitted(entries)
    # Remove entries already sent to WFM
    cached_existing_time_entries = {}
    entries.each do |sheet, days|
      # Handle timesheets that aren't setup in timetrap.yml
      unless Timetrap::Config['wfm']['aliases'].keys.include?(sheet)
        puts "Timetrap sheet '#{sheet}' not configured with WFM details; skipping..."
        entries.delete(sheet)
        next
      end
      task_id = Timetrap::Config['wfm']['aliases'][sheet]['task'].to_s
      days.each do |day, _details|
        unless cached_existing_time_entries.keys.include?(day)
          cached_existing_time_entries[day] =
            @client.current_time_entries(@my_id, day)
          # Days with a single entry will be a returned as a Hash, and days
          # with multiple entries will be an array of hashes. Here we'll make
          # them always be arrays for simplicity.
          if !cached_existing_time_entries[day].nil? &&
             cached_existing_time_entries[day]['Time'].class == Hash
            cached_existing_time_entries[day]['Time'] =
              [cached_existing_time_entries[day]['Time']]
          end
        end
        entries[sheet].delete(day) if
          !cached_existing_time_entries[day].nil? &&
          cached_existing_time_entries[day]['Time'].find { |t| t['Task']['ID'] == task_id }
      end
      entries.delete(sheet) if entries[sheet] == {}
    end
    entries
  end
end
