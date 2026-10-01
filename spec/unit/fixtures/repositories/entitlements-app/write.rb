# frozen_string_literal: true

module Entitlements
  class Rule
    class EntitlementsApp
      class Write < Entitlements::Rule::Base
        def members
          Set.new([Entitlements.cache[:people_obj].read("DwelF")])
        end
      end
    end
  end
end
