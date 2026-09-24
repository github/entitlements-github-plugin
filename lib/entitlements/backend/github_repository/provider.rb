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
          return if instructions.empty?
          action = Entitlements::Models::Action.new(desired.dn,
            snapshot(existing, current), snapshot(desired, effective), group_name, ignored_users: ignored)
          instructions.sort_by { |instruction| [instruction[:action] == :upsert ? 0 : 1, instruction[:login].downcase] }.each do |instruction|
            action.add_implementation(instruction)
          end
          action
        end

        def commit(action)
          unless action.existing.is_a?(Models::RepositoryAccess) && action.updated.is_a?(Models::RepositoryAccess) &&
              action.existing.dn == action.updated.dn && action.implementation.is_a?(Array)
            GitHubRepository.fail!("Invalid repository action")
          end
          @github.apply(action.updated.repository, action.implementation)
        end

        private

        def snapshot(source, roles)
          Models::RepositoryAccess.new(repository: source.repository, roles: roles, ou: @config.fetch("base"))
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
