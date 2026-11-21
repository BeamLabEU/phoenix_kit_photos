# PhoenixKit Photos contributor guidance

## Design for every installation

Never hardcode a choice that can vary by installation, environment, library, or user. Read the choice from the settings of the site or person who owns it. Discover available options from the registry and each integration’s declared capabilities, respecting ownership and permissions. Keep vendor-specific behavior inside its adapter.

For example, a bucket’s **Configure CDN** action opens the CDN-capable integrations available to its owner, even when only one provider qualifies. Registering a second compatible provider should make it available without editing the bucket screen.
