# Customer REST walkthrough

Import the collection and customer environment. Set `baseDomain`, `tenantSubdomain`
and `tenantName` in a private environment. Use a separate environment for each tenant.
The installation must already have completed platform setup and provisioned the
`developer-postman` public client with redirect URI
`https://oauth.pstmn.io/v1/browser-callback` on the platform and default tenant AS.

1. Send **00 Start here / 01 Discover platform OAuth endpoints**. On **01 Platform -
   create tenant**, choose **Authorization > Get New Access Token**, sign in as the
   platform operator, and choose **Use Token**. Send **00 List tenants** first. When a
   tenant with the slug `tenantSubdomain` already exists, it sets `tenantId` and the
   registration and status requests are skipped; continue at step 2 and sign in with the
   owner account you already activated. Otherwise create the tenant and repeat the status
   request until `COMPLETED`.
2. Open the returned `tenantOwnerActivationLink` in a browser, or use the invitation
   email. Complete the owner's activation. On **02 Tenant owner - register application**,
   send discovery, then get a new OAuth token as that tenant owner. Set
   `tenantServiceClientId` and a private local `tenantServiceClientSecret`. Resolve the
   tenant's default AS, list its registered applications and register the confidential
   application. When it is already registered, registration is skipped and **02a** sets its
   secret to your `tenantServiceClientSecret`, because a stored secret cannot be read back.
3. On **03 Tenant application**, choose **Get New Access Token** and **Use Token**.
   This uses client credentials at the discovered tenant token endpoint. All ordinary
   tenant REST requests inherit this configuration. Refresh the token here when needed.

Each tenant section starts with a list request, and a read-one request where it helps, so
you see the live objects before changing anything: authorization servers, issuers,
verifiers, KMS resources, credential designs and configurations, status lists and DCQL
queries. Their tests store the ids in collection variables and reuse objects that already
exist, so you can run the collection again against the same tenant.

Keep the imported advanced token parameters on **03 Tenant application**. They send
one `audience` body parameter for each registered tenant workload, including KMS and
issuance. Postman requests and manages the resulting token.

Postman owns these access tokens. Do not add an `Authorization` header or variables
named `platformAccessToken`, `tenantBootstrapAccessToken`, or `tenantAccessToken`.
Variables carry deployment inputs and response identifiers; they do not select the
administrative bearer. OAuth configuration is a Postman application feature: Newman
does not interactively open the login window or acquire these helper tokens.

Run the folders you need interactively. **Run All** is not appropriate: the Azure,
Keycloak, subtenant and credential-format examples are alternative or optional stories.
The pre-authorized OID4VCI grant remains an explicit token request because Postman's
OAuth helper does not support that grant. Its wallet token never authorizes tenant administration.

## Azure Key Vault

For a tenant-owned vault, use **03 / 07 Azure Key Vault and external keys**. Set the
vault URI, Entra directory ID, client ID and private client secret. Create the resource,
attach its credential using the returned `credentialSecretRef` and resource version,
and validate it. The `krh_...` handle addresses configuration; `providerId` addresses
the KMS runtime. Supply an existing Azure key alias and its matching public DER
certificate chain for the external-reference requests. Private keys stay in Azure.

For a platform-owned shared vault, the operator uses **04 Platform - shared Azure vault**
with the actual platform tenant ID. The tenant application then uses **03 / 08 Enable
shared Azure provider**. Set `tenantAzureProviderId` to that offered provider ID and
continue at request 04 of the external-reference folder, skipping tenant resource creation.
Sharing authorizes the named tenants; it does not expose platform keys or another tenant's keys.

## Hosted wallet AS with Keycloak upstream

Use **03 / 09 Keycloak wallet proxy**. The tenant default AS remains local-only for
administration. A separate hosted AS at `/as/wallet-proxy` owns wallet clients and tokens.

In Keycloak create a confidential OIDC client with Standard Flow enabled and this exact
redirect URI (substitute your tenant and slug):

```text
https://acme.example.com/as/wallet-proxy/federation/callback
```

Set `keycloakIssuer` to the realm issuer, `federationClientId` to that Keycloak client ID,
and `federationClientSecret` to its private secret. The REST steps create the hosted AS,
register the Postman wallet client, register Keycloak as `HOSTED_LOGIN_UPSTREAM`, create
and validate the federation binding, enable it, and bind the **hosted** AS to the issuer.
Keycloak does not need OID4VCI support for this mode.

Use **03 / 20 Authorization code through Keycloak** to select the proxy for `EuPid`,
create and resolve an offer, and discover the issuer and hosted AS endpoints. On its
**05 Wallet credential request** subfolder, get a token with authorization code and
PKCE. Check Advanced authorization parameters `issuer_state` and `authorization_details`.
Sign in at Keycloak; the code and wallet token come from the hosted AS. Choose **Use Token**.

Copy `authorization_details[].credential_identifiers[0]` from that token response to
`walletCredentialIdentifier`. Fetch a fresh nonce and have your wallet sign the holder
proof JWT with its own key, the credential issuer as audience, and that nonce. Set
`walletProofJwt`, then send the credential request. These two inputs are protocol output
and a holder proof, not administrative access-token variables. Remove the EuPid override
before returning to EuPid pre-authorized issuance; other credential configurations keep
their existing AS selection.

Saved examples are labeled **Previously captured response (sanitized)**. They show
response shapes from earlier executions, not proof that a newly configured vault or
Keycloak realm works. The response from your own Send operation is authoritative.
Changed proxy requests have no fabricated successful response examples.
