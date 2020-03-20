#!/usr/bin/env ruby

require 'net/http'
require 'open-uri'
require 'json'

USAGE = '`check_github_vulnerabilities.rb <access_token> <organization_name>`'.freeze

if ARGV[0].nil?
  puts "UNKNOWN: Missing GitHub personal access token - usage: #{USAGE}"
  exit 3
end

if ARGV[1].nil?
  puts "UNKNOWN: Missing GitHub organization name - usage: #{USAGE}"
  exit 3
end

GITHUB_OAUTH_TOKEN = ARGV[0].freeze
ORGANIZATION_NAME = ARGV[1].freeze

class GitHub
  Result = Struct.new(:repos, :cursor, :more?)
  Repo = Struct.new(:url, :alerts)
  Alert = Struct.new(:package_name, :affected_range, :fixed_in, :details)

  BASE_URI = 'https://api.github.com/graphql'.freeze

  def vulnerable_repos
    @vulnerable_repos ||= fetch_vulnerable_repos
  end

  def fetch_vulnerable_repos
    vulnerable_repos = repositories.select do |repo|
      next if repo['vulnerabilityAlerts']['nodes'].empty?

      repo['vulnerabilityAlerts']['nodes'].detect { |v| v['dismissedAt'].nil? }
    end

    vulnerable_repos.map do |repo|
      alerts = repo['vulnerabilityAlerts']['nodes'].map do |alert|
        Alert.new(alert['packageName'],
                  alert['affectedRange'],
                  alert['fixedIn'],
                  alert['externalReference'])
      end

      url = "https://github.com/#{repo['nameWithOwner']}"

      Repo.new(url, alerts)
    end
  end

  private

  def repositories
    cursor = nil
    repos = []

    loop do
      result = fetch_repositories(cursor: cursor)
      repos << result.repos
      cursor = result.cursor
      break unless result.more?
    end

    repos.flatten!
  end

  def fetch_repositories(cursor: nil)
    pagination_params = 'first: 25'
    pagination_params += "after: \"#{cursor}\"" if cursor

    query = <<-GRAPHQL
      query {
        organization(login: \"#{ORGANIZATION_NAME}\") {
          repositories(isFork:false #{pagination_params}) {
            pageInfo {
              startCursor
              endCursor
              hasNextPage
            }
            nodes {
              nameWithOwner
              vulnerabilityAlerts(first: 10) {
                nodes {
                  packageName
                  affectedRange
                  externalReference
                  fixedIn
                  dismissedAt
                }
              }
            }
          }
        }
      }
    GRAPHQL

    json = JSON.generate(query: query)

    uri = URI(BASE_URI)

    req                  = Net::HTTP::Post.new(uri)
    req.body             = json
    req['Authorization'] = "Bearer #{GITHUB_OAUTH_TOKEN}"
    req['Accept']        = 'application/vnd.github.vixen-preview+json'

    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
      http.request(req)
    end

    res.value

    body = JSON.parse(res.body)['data']['organization']['repositories']

    Result.new(
      body['nodes'],
      body['pageInfo']['endCursor'],
      body['pageInfo']['hasNextPage']
    )
  end
end

begin
  github = GitHub.new

  if github.vulnerable_repos.any?
    total_vulnerabilities = github.vulnerable_repos.sum { |repo| repo.alerts.length }
    puts "WARNING: #{total_vulnerabilities} vulnerabilities in #{github.vulnerable_repos.length} repos"

    github.vulnerable_repos.each do |repo|
      puts repo.url

      repo.alerts.each do |alert|
        puts "  #{alert.package_name} (#{alert.affected_range})"
        puts "  Fixed in: #{alert.fixed_in}"
        puts "  Details: #{alert.details}"
        puts
      end
    end

    exit 1
  else
    puts "OK: No vulnerabilities"
    exit 0
  end
rescue => e
  puts "UNKNOWN: #{e.to_s}\n#{e.full_message}"
  exit 3
end
