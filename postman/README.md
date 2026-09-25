# Postman collection

`EDK-Enterprise-Deployment.postman_collection.json` walks through what developers usually do
with an EDK Enterprise installation: pick or create a tenant, create a service client for their
application, and then call the tenant APIs to manage keys, issue and verify credentials, and
publish status and trust information. It mirrors the guides in the developer console.

Import the collection and `EDK-Enterprise-Deployment.customer.postman_environment.json`. Keep a
separate copy of the environment per installation or tenant.

## Two values to set

| Variable | Example | Meaning |
| --- | --- | --- |
| `baseDomain` | `example.com` | The installation's base domain. Add `:port` only if your gateway listens on a non-standard port. |
| `tenantSlug` | `acme` | The tenant you work with. |

Everything follows from these two. The platform is at `https://platform.<baseDomain>` and the
tenant at `https://<tenantSlug>.<baseDomain>`, including the tenant's authorization server at
`https://<tenantSlug>.<baseDomain>/as/<tenantSlug>`. There are no URL variables to maintain.

`tenantName` is only used when you register a tenant. `serviceClientId` and
`serviceClientSecret` identify your service client (see folder 2). The other variables belong to
the optional Azure Key Vault and Keycloak folders and can stay empty until you use them.

## How the collection is organized

The three top-level folders match the three identities you act as. Each folder has its own
OAuth2 configuration. Open the folder, go to **Authorization**, choose **Get New Access Token**,
then **Use Token**. Postman keeps the token with the folder and every request in it uses it.
Tokens last an hour; get a new one when requests start returning 401.

### 1. Platform operator

Sign in with the platform operator account. You need this folder only to see or create tenants,
not for daily tenant work.

- **Tenants**: *List tenants* shows all tenants and remembers the one whose slug is `tenantSlug`.
  *Register tenant* creates it when it does not exist (it skips itself otherwise). Registration
  also provisions the tenant's authorization server, issuer, verifier, keys, DID and sample data.
  When no email transport is configured, the response and the Postman console show
  `delivery.manualActivationLink`: open it in a browser to set the tenant owner's password. The
  owner signs in with the technical contact email, `admin@<tenantSlug>.example` in the example body.
- **Child tenants (optional)**: list and register child tenants.
- **Share an Azure Key Vault with tenants (optional)**: see [Azure Key Vault](#azure-key-vault).

### 2. Tenant owner: create a service client

Your application calls the tenant APIs as a **service client**: an OAuth2 client of the tenant's
own authorization server that uses the client credentials grant. No user is involved. You create
it once, either here or in the admin console under **Authorization server > Clients**.

Sign in as the tenant owner, then run the folder:

1. *List authorization servers* finds the tenant's default authorization server and the tenant id.
2. *List service clients* shows the existing clients.
3. *Create the service client* registers `serviceClientId` with the audiences of all tenant
   services. The server never returns a secret, so you choose it: when `serviceClientSecret` is
   empty, the request generates a random one and stores it in your environment.
4. *Replace the service client secret* stores `serviceClientSecret` as the new secret. Use it
   when you no longer have the secret of an existing client.

If you created the client in the admin console, put its id and secret in the environment and skip
this folder.

### 3. Tenant APIs

Everything else runs on the tenant host with the service client's token. The folder requests one
token that is valid for every tenant service (one `audience` parameter per service). Some paths
contain the tenant id; when it is not known yet, the folder script looks it up with the service
client's credentials.

| Folder | What you do |
| --- | --- |
| Authorization server | Read the authorization servers and clients. |
| Keys and DIDs | List KMS resources and providers, generate a key, sign and verify, read the tenant DID and its public `did.json`. |
| Azure Key Vault (optional) | Use your own vault or one the platform shares. |
| Credential issuer | Read the issuer, its credential configurations and its public metadata. |
| Credential designs | Read the designs that control how wallets display credentials. |
| Status lists | Read the status lists and the public status list token. |
| Define your own credential | Add an `EmployeeBadge` SD-JWT VC: a status list, a design, and the credential configuration. |
| Issue credentials | Create offers (from a template, for EuPid, and for EmployeeBadge with a transaction code), receive the credential in a test wallet, and revoke it. |
| Verify credentials | Create a DCQL query, bind it to the verifier, create an authorization request from a template or a query, and poll its result. |
| Trust domains | Read the trust domains, anchors and attachments that decide which issuers the verifier accepts. |
| Keycloak wallet login (optional) | Let wallet users sign in at Keycloak before they receive a credential. |

Each folder starts by listing what exists. The list requests store the ids that later requests
need, and create requests skip themselves when the object already exists, so you can run a folder
again. Start a folder at its first request. Postman's console (**View > Show Postman Console**)
shows what each request found or skipped.

Switching `tenantSlug` clears the ids captured for the previous tenant.

## Issue and receive a credential

*Issue credentials* creates an offer and prints its `openid-credential-offer://` link, which you
can turn into a QR code for a real wallet. The **Receive it in a test wallet** folder plays the
wallet instead: it resolves the last offer, reads the issuer and authorization server metadata,
redeems the pre-authorized code (with the transaction code when the offer asks for one), fetches
a nonce and requests the credential. The folder script generates a P-256 key in the Postman
sandbox and signs the holder proof with it. The wallet's access token is protocol output, not an
administrative token.

After you received an SD-JWT VC, *Find the status list of the credential* and *Revoke the issued
credential* set its status entry, and verifiers see it as revoked.

## Azure Key Vault

Keys in Azure Key Vault never leave Azure. You need an Entra app registration that may use the
vault's keys, and in the environment:

| Variable | Value |
| --- | --- |
| `azureVaultUri` | `https://<vault-name>.vault.azure.net` |
| `azureDirectoryId` | The Entra tenant (directory) id |
| `azureClientId` | The app registration's client id |
| `azureClientSecret` | Its client secret |
| `azureKeyName` | Optional: an existing key to register (bring your own key) |
| `azureCertificateChain` | Optional: the base64 DER certificate of that key (bring your own certificate) |

**Your own vault**: run *3. Tenant APIs > Azure Key Vault > Use your own vault*. It connects the
vault as a KMS resource, stores the client secret (write-only), validates the connection, and
generates a key in the vault. With `azureKeyName` set it registers that existing key, and with
`azureCertificateChain` also its certificate. Registered keys and certificates are references:
removing them from EDK never deletes them from Azure.

**A vault shared by the platform**: the platform operator runs *1. Platform operator > Share an
Azure Key Vault with tenants* with the same inputs. It registers the vault for the platform and
offers it to the tenant `tenantSlug` (run *List tenants* first). The tenant then runs *3. Tenant
APIs > Azure Key Vault > Use a vault shared by the platform* to enable it and generate a key in
it. Tenants never see the vault credentials or each other's keys.

## Keycloak wallet login

With the OID4VCI authorization code flow, the wallet user signs in before the credential is
issued. The collection sets up a second authorization server on the tenant, the **wallet proxy**
at `https://<tenantSlug>.<baseDomain>/as/wallet-proxy`, which sends users to Keycloak. The
tenant's default authorization server is not changed.

1. In Keycloak, create a confidential OpenID Connect client with the standard flow and the redirect
   URI `https://<tenantSlug>.<baseDomain>/as/wallet-proxy/federation/callback`. Keycloak needs no
   OID4VCI support, but it must be reachable from the EDK installation.
2. Set `keycloakIssuer` (for example `https://idp.example.com/realms/acme`), `keycloakClientId`
   and `keycloakClientSecret`.
3. Run *3. Tenant APIs > Keycloak wallet login > Set up the wallet proxy*. It creates the wallet
   proxy and a public Postman wallet client, registers Keycloak, connects the two with a
   federation binding, and allows the issuer to use the wallet proxy.
4. Run *Issue EuPid with a Keycloak login* up to the **6. Wallet: request the credential** folder.
   The first request points EuPid at the wallet proxy and the next ones create and resolve an
   authorization code offer.
5. On the **6. Wallet: request the credential** folder, choose **Get New Access Token**. The
   request carries the offer's `issuer_state` and `authorization_details`. Sign in at Keycloak and
   choose **Use Token**. Copy `authorization_details[0].credential_identifiers[0]` from the token
   response into `walletCredentialIdentifier`, then send *Request the credential*.
6. Send the last request to switch EuPid back to the default authorization server. While EuPid uses
   the wallet proxy it only allows the authorization code grant, so the pre-authorized EuPid offers
   in *Issue credentials* are refused.

## Running folders

You can run a folder with Postman's collection runner once its OAuth2 token is in place. Do not
run the whole collection in one go: the three top-level folders need three different sign-ins,
and the optional folders skip themselves until you set their inputs.

## When something fails

| Response | Likely cause |
| --- | --- |
| 401 | The folder has no token or it expired. Get a new token on the folder. |
| 403 on a tenant request | The token comes from another tenant or lacks the service's audience. Get a new token on folder 3 after changing `tenantSlug`. |
| 404 on a request with an id in the path | An earlier list or create request did not run. Start the folder at its first request. |
| `Skipped: ...` in the console | The request needs an input or an earlier step. The message says which. |
