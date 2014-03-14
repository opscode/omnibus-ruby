#
# Copyright:: Copyright (c) 2012-2014 Chef Software, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

module Omnibus
  class UnsupportedURIScheme < ArgumentError
  end

  class InvalidSourceFile < RuntimeError
  end

  # Fetcher Implementation for HTTP and FTP hosted tarballs
  class NetFetcher < Fetcher
    name :net

    attr_reader :name
    attr_reader :project_file
    attr_reader :source
    attr_reader :source_uri
    attr_reader :source_dir
    attr_reader :project_dir

    def initialize(software)
      @name         = software.name
      @checksum     = software.checksum
      @source       = software.source
      @project_file = software.project_file
      @source_uri   = software.source_uri
      @source_dir   = software.source_dir
      @project_dir  = software.project_dir
    end

    def description
      <<-E
source URI:     #{source_uri}
checksum:       #{@checksum}
local location: #{@project_file}
E
    end

    def version_guid
      "md5:#{@checksum}"
    end

    def fetch_required?
      !File.exist?(project_file) || Digest::MD5.file(project_file) != @checksum
    end

    def clean
      if File.exist?(project_dir)
        log "cleaning existing build from #{project_dir}"
        FileUtils.rm_rf(project_dir)
      end
      extract
    end

    def fetch
      if fetch_required?
        download
        verify_checksum!
      else
        log 'Cached copy of source tarball up to date'
      end
    end

    def get_with_redirect(url, headers, limit = 10)
      fail ArgumentError, 'HTTP redirect too deep' if limit == 0
      log "getting from #{url} with #{limit} redirects left"

      url = URI.parse(url) unless url.kind_of?(URI)

      req = Net::HTTP::Get.new(url.request_uri, headers)

      http_client = if http_proxy && !excluded_from_proxy?(url.host)
                      Net::HTTP::Proxy(http_proxy.host, http_proxy.port, http_proxy.user, http_proxy.password).new(url.host, url.port)
                    else
                      Net::HTTP.new(url.host, url.port)
                    end
      http_client.use_ssl = (url.scheme == 'https')

      response = http_client.start { |http| http.request(req) }
      case response
      when Net::HTTPSuccess
        open(project_file, 'wb') do |f|
          f.write(response.body)
        end
      when Net::HTTPRedirection
        get_with_redirect(response['location'], headers, limit - 1)
      else
        response.error!
      end
    end

    # search environment variable as given, all lowercase and all upper case
    def get_env(name)
      ENV[name] || ENV[name.downcase] || ENV[name.upcase] || nil
    end

    # constructs a http_proxy uri from HTTP_PROXY* env vars
    def http_proxy
      @http_proxy ||= begin
        proxy = get_env('HTTP_PROXY') || return
        proxy = "http://#{proxy}" unless proxy =~ /^https?:/
        uri = URI.parse(proxy)
        uri.user ||= get_env('HTTP_PROXY_USER')
        uri.password ||= get_env('HTTP_PROXY_PASS')
        uri
      end
    end

    # return true if the host is excluded from proxying via the no_proxy directive.
    # the 'no_proxy' variable contains a list of host suffixes separated by comma
    # example: example.com,www.examle.org,localhost
    def excluded_from_proxy?(host)
      no_proxy = get_env('no_proxy') || ''
      no_proxy.split(/\s*,\s*/).any? { |pattern| host.end_with? pattern }
    end

    def download
      tries = 5
      begin
        log "\033[1;31m#{source[:warning]}\033[0m" if source.key?(:warning)
        log "fetching #{project_file} from #{source_uri}"

        case source_uri.scheme
        when /https?/
          headers = {
            'accept-encoding' => '',
          }
          if source.key?(:cookie)
            headers['Cookie'] = source[:cookie]
          end
          get_with_redirect(source_uri, headers)
        when 'ftp'
          Net::FTP.open(source_uri.host) do |ftp|
            ftp.passive = true
            ftp.login
            ftp.getbinaryfile(source_uri.path, project_file)
            ftp.close
          end
        else
          fail UnsupportedURIScheme, "Don't know how to download from #{source_uri}"
        end
      rescue Exception
        tries -= 1
        if tries != 0
          log 'retrying failed download...'
          retry
        else
          raise
        end
      end
    rescue Exception => e
      ErrorReporter.new(e, self).explain("Failed to fetch source from #source_uri (#{e.class}: #{e.message.strip})")
      raise
    end

    def verify_checksum!
      actual_md5 = Digest::MD5.file(project_file)
      unless actual_md5 == @checksum
        log "Invalid MD5 for #{@name}"
        log "Expected: #{@checksum}"
        log "Actual:   #{actual_md5}"
        fail InvalidSourceFile, "Checksum of downloaded file #{project_file} doesn't match expected"
      end
    end

    def extract
      log "extracting the source in #{project_file} to #{source_dir}"
      cmd = extract_cmd
      case cmd
      when Proc
        cmd.call
      when String
        shell = Mixlib::ShellOut.new(cmd, live_stream: STDOUT)
        shell.run_command
        shell.error!
      else
        fail "Don't know how to extract command for #{cmd.class} class"
      end
    rescue Exception => e
      ErrorReporter.new(e, self).explain("Failed to unpack archive at #{project_file} (#{e.class}: #{e.message.strip})")
      raise
    end

    def extract_cmd
      if project_file.end_with?('.gz') || project_file.end_with?('.tgz')
        "gzip -dc  #{project_file} | ( cd #{source_dir} && tar -xf - )"
      elsif project_file.end_with?('.bz2')
        "bzip2 -dc  #{project_file} | ( cd #{source_dir} && tar -xf - )"
      elsif project_file.end_with?('.7z')
        "7z.exe x #{project_file} -o#{source_dir} -r -y"
      elsif project_file.end_with?('.zip')
        "unzip #{project_file} -d #{source_dir}"
      elsif project_file.end_with?('.xz') || project_file.end_with?('.txz')
        "xz -dc #{project_file} | ( cd #{source_dir} && tar -xf - )"
      else
        # if we don't recognize the extension, simply copy over the file
        proc do
          log "#{project_file} not an archive. Copying to #{project_dir}"
          # WARNING: hack hack hack, no project dir yet
          FileUtils.mkdir_p(project_dir)
          FileUtils.cp(project_file, project_dir)
        end
      end
    end
  end
end
