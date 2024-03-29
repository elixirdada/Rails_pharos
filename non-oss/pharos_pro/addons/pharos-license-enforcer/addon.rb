# frozen_string_literal: true

Pharos.addon 'pharos-license-enforcer' do
  version '0.2.0'
  license 'Kontena License'

  enable!

  install do
    apply_resources
    post_install_message(<<~POST_INSTALL_MESSAGE)
      To assign a license to the cluster, use the #{'pharos license assign'.cyan} command.
    POST_INSTALL_MESSAGE
  end
end
