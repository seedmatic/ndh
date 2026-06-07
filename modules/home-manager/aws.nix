{ ... }:
{
  # Declarative AWS CLI profile configuration (safe to version-control).
  # Do not store ~/.aws/credentials or ~/.aws/sso/cache in git.
  home.file.".aws/config".text = ''
    [profile hyland]
    sso_session = hyland
    region = us-east-1
    output = yaml-stream

    [profile ai-tools-shared]
    sso_session = hyland
    sso_account_id = 445316526014
    sso_role_name = AWSPowerUserAccess
    region = us-east-1
    output = yaml-stream

    [profile hxpr-prod]
    sso_session = hyland
    sso_account_id = 899819996571
    sso_role_name = AWSPowerUserAccess
    region = us-east-1
    output = yaml-stream

    [profile hxpr-staging]
    sso_session = hyland
    sso_account_id = 752259584717
    sso_role_name = AWSPowerUserAccess
    region = us-east-1
    output = yaml-stream

    [profile hxpr-dev]
    sso_session = hyland
    sso_account_id = 521949321236
    sso_role_name = AWSAdministratorAccess
    region = us-east-1
    output = yaml-stream

    [profile hxpr-prod-eu]
    sso_session = hyland
    sso_account_id = 637423237543
    sso_role_name = AWSPowerUserAccess
    region = eu-central-1
    output = yaml-stream

    [sso-session hyland]
    sso_start_url = https://identitycenter.amazonaws.com/ssoins-6684b922d5a25f41
    sso_region = us-east-2
    sso_registration_scopes = sso:account:access
  '';
}
