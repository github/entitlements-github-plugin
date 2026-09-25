# frozen_string_literal: true

module Entitlements
  class Backend
    class GitHubRepository
      class Provider < Entitlements::Backend::BaseProvider
        def initialize(config:)
          @config = config
          @github = Service.new(org: config.fetch("org"), token: config.fetch("token"),
            ou: config.fetch("base"), addr: config["addr"])
        end

        def action_for(desired, group_name)
          ignored = Set.new(@config.fetch("ignore", []).map(&:downcase))
          validate_members(desired, ignored)
          existing = @github.read_repository(desired.repository)
          current = existing.roles.reject { |login, _| ignored.include?(login) }
          target = desired.roles.reject { |login, _| ignored.include?(login) }
          effective = current.dup
          instructions = []
          (current.keys | target.keys).sort.each do |login|
            before = current[login]
            after = target[login]
            next if before == after
            feature = if before.nil?
                        "add"
            elsif after.nil?
              "remove"
            else
              "update"
            end
            next unless @config.fetch("features", FEATURES).include?(feature)
            if after
              effective[login] = after
              instructions << { action: :upsert, login: desired.login_for(login), permission: ROLES.fetch(after) }
            else
              effective.delete(login)
              instructions << { action: :remove, login: existing.login_for(login) }
            end
            name = after ? desired.login_for(login) : existing.login_for(login)
            Entitlements.logger.info "CHANGE #{desired.repository}: #{name} #{before || '(none)'} -> #{after || '(none)'}"
          end
          teams = existing.teams.values
          if @config.fetch("features", FEATURES).include?("remove")
            existing.ordered_teams.each do |team|
              instructions << { action: :remove_team, team_id: team[:id], slug: team[:slug] }
              Entitlements.logger.info "CHANGE #{desired.repository}: team #{@config.fetch('org')}/#{team[:slug]} (granted) -> (none)"
            end
            teams = []
          elsif !teams.empty?
            Entitlements.logger.warn("#{desired.repository}: remove disabled; individual-only repository grants are not enforced")
          end
          Entitlements.logger.info "#{desired.repository}: organization-level access and repository visibility are unchanged"
          return if instructions.empty?
          action = Entitlements::Models::Action.new(desired.dn,
            snapshot(existing, current), snapshot(desired, effective, teams: teams), group_name, ignored_users: ignored)
          instructions.partition { |instruction| instruction[:action] == :upsert }.flatten.each do |instruction|
            action.add_implementation(instruction)
          end
          action
        end

        def commit(action)
          unless action.existing.is_a?(Models::RepositoryAccess) && action.updated.is_a?(Models::RepositoryAccess) &&
              action.existing.dn == action.updated.dn && action.implementation.is_a?(Array)
            GitHubRepository.fail!("Invalid repository action")
          end
          current = @github.read_repository(action.updated.repository, refresh: true)
          unless filtered_snapshot(current, action.ignored_users) == action.existing
            GitHubRepository.fail!("Repository grants changed since calculation; recalculate before applying")
          end
          @github.apply(action.updated.repository, action.implementation)
          current = @github.read_repository(action.updated.repository, refresh: true)
          unless filtered_snapshot(current, action.ignored_users) == action.updated
            GitHubRepository.fail!("Repository grants did not converge for #{action.updated.repository}; recalculate before retrying")
          end
        end

        private

        def snapshot(source, roles, teams: source.teams.values)
          Models::RepositoryAccess.new(repository: source.repository, roles: roles, teams: teams, ou: @config.fetch("base"))
        end

        def filtered_snapshot(source, ignored)
          snapshot(source, source.roles.reject { |login, _| ignored.include?(login) })
        end

        def validate_members(desired, ignored)
          invalid = desired.roles.keys - @github.active_members.keys - ignored.to_a
          return if invalid.empty?
          message = "#{desired.repository}: not active non-owner organization members: #{invalid.join(', ')}"
          GitHubRepository.fail!(message) unless @config.fetch("ignore_not_found", false)
          Entitlements.logger.warn("#{message}; ignored")
          ignored.merge(invalid)
        end
      end
    end
  end
end
