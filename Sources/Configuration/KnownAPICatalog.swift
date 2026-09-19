//
//  KnownAPICatalog.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 19/09/2026.
//

import Foundation

/// A built-in catalog of well-known third-party API hosts, so a request the
/// developer never tagged still arrives with a name a human recognises.
///
/// ## Why this exists
///
/// Tagging used to be entirely opt-in: whatever `SwiftyDebug.addTag(keyword:label:)`
/// was given got a pill, and everything else showed a bare host. A real session
/// is mostly third-party traffic — analytics, crash reporters, CDNs, payment
/// SDKs — none of which the app author ever names, and all of which then look
/// identical in the list. This turns `graph.facebook.com` into "Facebook" and
/// `firebaselogging-pa.googleapis.com` into "Firebase" without anyone
/// configuring anything.
///
/// ## Matching
///
/// Entries are keyed by **registrable-ish domain suffix**, not by substring. A
/// host matches an entry when the entry is the host itself or a dot-delimited
/// suffix of it, so `55c0a1-dsn.algolia.net` matches `algolia.net` while
/// `notalgolia.net` does not — which is exactly the failure substring matching
/// produced. Lookup walks the host's labels from most specific to least, so
/// `firebaselogging-pa.googleapis.com` prefers its own entry over the broader
/// `googleapis.com`. That walk is at most a handful of dictionary hits.
///
/// Precedence overall (see `TagResolver`): a developer's own tag always wins,
/// then this catalog, then a host-derived fallback. Nothing here can override a
/// tag the app author set.
enum KnownAPICatalog {

    /// Domain suffix -> display label. Lowercased keys, no leading dot.
    ///
    /// Kept as one flat table rather than per-category arrays because lookup is
    /// a suffix walk and every category would have to be searched anyway.
    static let entries: [String: String] = {
        var map: [String: String] = [:]
        for (label, domains) in grouped {
            for domain in domains {
                map[domain] = label
            }
        }
        return map
    }()

    /// The catalog's source form: one label, every domain that should carry it.
    /// Grouping by label keeps the table readable and makes a wrong label a
    /// one-line fix rather than a find-and-replace.
    static let grouped: [(label: String, domains: [String])] = [

        // MARK: - Search / discovery

        ("Algolia", ["algolia.net", "algolianet.com", "algolia.io", "algolia.com", "insights.algolia.io", "places.algolia.com", "crawler.algolia.com"]),
        ("Elasticsearch", ["elastic.co", "elastic-cloud.com", "found.io", "elasticsearch.com"]),
        ("Typesense", ["typesense.net", "typesense.org"]),
        ("Meilisearch", ["meilisearch.com", "meilisearch.dev"]),
        ("Constructor", ["constructor.io", "cnstrc.com"]),
        ("Bloomreach", ["bloomreach.io", "bloomreach.com", "brsrvr.com"]),
        ("Klevu", ["klevu.com"]),
        ("Searchspring", ["searchspring.io", "searchspring.net"]),
        ("Coveo", ["coveo.com", "cloud.coveo.com"]),
        ("Swiftype", ["swiftype.com"]),
        ("Yext", ["yext.com", "yextapis.com"]),
        ("Lucidworks", ["lucidworks.com"]),

        // MARK: - Analytics / product analytics

        ("Segment", ["segment.com", "segment.io", "segmentapis.com", "cdn-settings.segment.com"]),
        ("Mixpanel", ["mixpanel.com", "mxpnl.com"]),
        ("Amplitude", ["amplitude.com", "amplitude.io"]),
        ("Heap", ["heap.io", "heapanalytics.com"]),
        ("PostHog", ["posthog.com", "i.posthog.com", "app.posthog.com"]),
        ("Pendo", ["pendo.io"]),
        ("FullStory", ["fullstory.com", "fs.fullstory.com"]),
        ("LogRocket", ["logrocket.com", "logrocket.io", "lr-ingest.io"]),
        ("Hotjar", ["hotjar.com", "hotjar.io"]),
        ("Smartlook", ["smartlook.com", "smartlook.cloud"]),
        ("Quantcast", ["quantserve.com", "quantcast.com"]),
        ("Comscore", ["scorecardresearch.com", "comscore.com"]),
        ("Chartbeat", ["chartbeat.com", "chartbeat.net"]),
        ("Matomo", ["matomo.cloud", "matomo.org"]),
        ("Plausible", ["plausible.io"]),
        ("Fathom", ["usefathom.com"]),
        ("Countly", ["count.ly", "countly.com", "countly.io"]),
        ("Snowplow", ["snowplowanalytics.com", "snplow.net"]),
        ("mParticle", ["mparticle.com"]),
        ("Tealium", ["tealiumiq.com", "tiqcdn.com", "tealium.com"]),
        ("Kochava", ["kochava.com", "kochava.net", "control.kochava.com"]),
        ("Singular", ["singular.net", "sng.link"]),
        ("Jitsu", ["jitsu.com", "jitsu.dev"]),
        ("RudderStack", ["rudderstack.com", "rudderlabs.com"]),
        ("Umami", ["umami.is"]),
        ("Clarity", ["clarity.ms"]),

        // MARK: - Attribution / mobile measurement

        ("Adjust", ["adjust.com", "adjust.io", "adj.st", "adjust.net.in", "adjust.world"]),
        ("AppsFlyer", ["appsflyer.com", "appsflyersdk.com", "onelink.me"]),
        ("Branch", ["branch.io", "app.link", "bnc.lt", "branchmetrics.io"]),
        ("Airbridge", ["airbridge.io", "abr.ge"]),
        ("Tenjin", ["tenjin.com", "tenjin.io"]),
        ("AppMetrica", ["appmetrica.yandex.net", "appmetrica.yandex.com"]),

        // MARK: - Crash reporting / monitoring / APM

        ("Crashlytics", ["crashlytics.com", "firebase-settings.crashlytics.com"]),
        ("Sentry", ["sentry.io", "ingest.sentry.io", "getsentry.com"]),
        ("Bugsnag", ["bugsnag.com", "bugsnag.net"]),
        ("Rollbar", ["rollbar.com"]),
        ("Raygun", ["raygun.com", "raygun.io"]),
        ("Instabug", ["instabug.com"]),
        ("Embrace", ["embrace.io"]),
        ("Datadog", ["datadoghq.com", "datadoghq.eu", "datad0g.com", "ddog-gov.com", "browser-intake-datadoghq.com"]),
        ("New Relic", ["newrelic.com", "nr-data.net", "newrelic.eu"]),
        ("Dynatrace", ["dynatrace.com", "live.dynatrace.com", "ruxit.com"]),
        ("AppDynamics", ["appdynamics.com", "eum-appdynamics.com"]),
        ("Elastic APM", ["apm.elastic.co"]),
        ("Grafana", ["grafana.net", "grafana.com", "grafana-dev.net"]),
        ("Honeycomb", ["honeycomb.io"]),
        ("Splunk", ["splunkcloud.com", "splunk.com", "signalfx.com"]),
        ("Loggly", ["loggly.com"]),
        ("Papertrail", ["papertrailapp.com"]),
        ("Logz.io", ["logz.io"]),
        ("Pingdom", ["pingdom.net", "pingdom.com"]),
        ("Better Stack", ["betterstack.com", "logtail.com", "betteruptime.com"]),
        ("Countly Crash", ["crash.count.ly"]),

        // MARK: - Google / Firebase

        ("Google APIs", ["googleapis.com"]),
        ("Firebase", ["firebaseio.com", "firebaseapp.com", "firebase.com", "firebaseinstallations.googleapis.com", "firebaseremoteconfig.googleapis.com", "firebasedynamiclinks.googleapis.com", "firebasestorage.googleapis.com", "firebaselogging-pa.googleapis.com", "firebaselogging.googleapis.com", "firestore.googleapis.com", "firebasedatabase.app", "firebaseinappmessaging.googleapis.com", "fcmregistrations.googleapis.com", "firebaseappcheck.googleapis.com"]),
        ("Google Analytics", ["google-analytics.com", "analytics.google.com", "app-measurement.com", "googletagmanager.com", "ssl.google-analytics.com"]),
        ("Google Ads", ["googleadservices.com", "googlesyndication.com", "doubleclick.net", "googletagservices.com", "admob.com", "googleads.g.doubleclick.net", "adservice.google.com"]),
        ("Google Maps", ["maps.googleapis.com", "maps.google.com", "mapsplatform.google.com"]),
        ("Google Sign-In", ["accounts.google.com", "oauth2.googleapis.com"]),
        ("Google Play", ["play.google.com", "android.clients.google.com", "play.googleapis.com"]),
        ("Google Fonts", ["fonts.googleapis.com", "fonts.gstatic.com"]),
        ("Google Static", ["gstatic.com", "googleusercontent.com"]),
        ("Google Cloud", ["cloudfunctions.net", "run.app", "appspot.com", "storage.googleapis.com", "cloud.google.com"]),
        ("reCAPTCHA", ["recaptcha.net", "www.recaptcha.net"]),
        ("YouTube", ["youtube.com", "youtubei.googleapis.com", "ytimg.com", "youtu.be", "googlevideo.com"]),
        ("Google", ["google.com", "google.co.uk", "google.de", "google.fr", "gvt1.com", "gvt2.com"]),

        // MARK: - Apple

        ("Apple", ["apple.com", "icloud.com", "cdn-apple.com", "mzstatic.com"]),
        ("App Store", ["itunes.apple.com", "apps.apple.com", "amp-api.apps.apple.com", "buy.itunes.apple.com", "sandbox.itunes.apple.com"]),
        ("APNs", ["push.apple.com", "api.push.apple.com", "api.sandbox.push.apple.com"]),
        ("Apple Maps", ["gsp-ssl.ls.apple.com", "gspe35-ssl.ls.apple.com", "cdn.apple-mapkit.com"]),
        ("iCloud", ["icloud.com.cn", "apple-cloudkit.com"]),
        ("CloudKit", ["api.apple-cloudkit.com"]),
        ("Apple Pay", ["apple-pay-gateway.apple.com"]),
        ("Sign in with Apple", ["appleid.apple.com"]),
        ("TestFlight", ["testflight.apple.com"]),

        // MARK: - Microsoft / Azure

        ("Azure", ["azure.com", "azurewebsites.net", "azureedge.net", "windows.net", "azure-api.net", "azurefd.net", "blob.core.windows.net", "trafficmanager.net"]),
        ("Microsoft Graph", ["graph.microsoft.com", "graph.microsoft.us"]),
        ("App Center", ["appcenter.ms", "in.appcenter.ms", "install.appcenter.ms"]),
        ("Application Insights", ["applicationinsights.azure.com", "dc.services.visualstudio.com", "in.applicationinsights.azure.com"]),
        ("Microsoft", ["microsoft.com", "microsoftonline.com", "live.com", "msn.com", "bing.com", "office.com", "office365.com", "sharepoint.com"]),
        ("Azure OpenAI", ["openai.azure.com"]),

        // MARK: - AWS

        ("AWS", ["amazonaws.com", "aws.amazon.com", "amazonaws.com.cn"]),
        ("Amazon S3", ["s3.amazonaws.com", "s3.us-east-1.amazonaws.com", "s3.eu-west-1.amazonaws.com"]),
        ("CloudFront", ["cloudfront.net"]),
        ("AWS Amplify", ["amplifyapp.com", "amplify.aws"]),
        ("AWS Cognito", ["cognito-idp.us-east-1.amazonaws.com", "auth.us-east-1.amazoncognito.com", "amazoncognito.com"]),
        ("Amazon", ["amazon.com", "media-amazon.com", "ssl-images-amazon.com", "amazon.co.uk", "amazon.de"]),
        ("Amazon Ads", ["amazon-adsystem.com", "assoc-amazon.com"]),

        // MARK: - Payments

        ("Stripe", ["stripe.com", "stripe.network", "js.stripe.com", "api.stripe.com", "m.stripe.com", "r.stripe.com", "hooks.stripe.com"]),
        ("PayPal", ["paypal.com", "paypalobjects.com", "paypal-api.com", "braintree-api.com", "braintreegateway.com", "braintreepayments.com"]),
        ("Adyen", ["adyen.com", "adyenpayments.com", "adyen.link"]),
        ("Checkout.com", ["checkout.com", "cko.com"]),
        ("Square", ["squareup.com", "square.com", "connect.squareup.com"]),
        ("Klarna", ["klarna.com", "klarnaservices.com", "klarnacdn.net"]),
        ("Afterpay", ["afterpay.com", "clearpay.co.uk"]),
        ("Razorpay", ["razorpay.com"]),
        ("PayU", ["payu.com", "payu.in", "payulatam.com"]),
        ("Mollie", ["mollie.com"]),
        ("Worldpay", ["worldpay.com", "fisglobal.com"]),
        ("Authorize.Net", ["authorize.net"]),
        ("Plaid", ["plaid.com"]),
        ("Wise", ["wise.com", "transferwise.com"]),
        ("Revolut", ["revolut.com"]),
        ("Coinbase", ["coinbase.com", "coinbase.net"]),
        ("RevenueCat", ["revenuecat.com", "api.revenuecat.com"]),
        ("Qonversion", ["qonversion.io"]),
        ("Adapty", ["adapty.io"]),
        ("Paddle", ["paddle.com", "paddle.net"]),
        ("Chargebee", ["chargebee.com"]),
        ("Recurly", ["recurly.com"]),
        ("Tap Payments", ["tap.company", "gosell.io"]),
        ("Moyasar", ["moyasar.com"]),
        ("HyperPay", ["hyperpay.com", "hyper-pay.com"]),
        ("PayTabs", ["paytabs.com", "paytabs.sa"]),
        ("Tamara", ["tamara.co"]),
        ("Tabby", ["tabby.ai", "tabby.dev"]),
        ("STC Pay", ["stcpay.com.sa"]),
        ("Mada", ["mada.com.sa"]),
        ("Fawry", ["fawry.com", "atfawry.com"]),
        ("Paymob", ["paymob.com"]),
        ("Network International", ["network.ae", "ngenius-payments.com"]),

        // MARK: - Push / messaging / engagement

        ("OneSignal", ["onesignal.com", "os.tc", "onesignal.io"]),
        ("Braze", ["braze.com", "braze.eu", "appboy.com", "iad-01.braze.com", "iad-02.braze.com", "iad-03.braze.com", "iad-05.braze.com", "iad-06.braze.com", "iad-07.braze.com", "iad-08.braze.com", "fra-01.braze.eu", "fra-02.braze.eu"]),
        ("CleverTap", ["clevertap.com", "wzrkt.com"]),
        ("MoEngage", ["moengage.com", "moengage.net"]),
        ("Airship", ["urbanairship.com", "airship.com", "asnapieu.com"]),
        ("Leanplum", ["leanplum.com"]),
        ("Iterable", ["iterable.com", "links.iterable.com"]),
        ("Customer.io", ["customer.io", "customerioapi.com", "track.customer.io"]),
        ("Pusher", ["pusher.com", "pusherapp.com"]),
        ("Ably", ["ably.io", "ably.com"]),
        ("PubNub", ["pubnub.com", "pndsn.com"]),
        ("Twilio", ["twilio.com", "twiliocdn.com"]),
        ("SendGrid", ["sendgrid.com", "sendgrid.net"]),
        ("Mailgun", ["mailgun.com", "mailgun.net"]),
        ("Mailchimp", ["mailchimp.com", "mailchimpapp.net", "list-manage.com"]),
        ("Postmark", ["postmarkapp.com"]),
        ("Intercom", ["intercom.io", "intercomcdn.com", "intercomassets.com", "intercom.com"]),
        ("Zendesk", ["zendesk.com", "zdassets.com", "zopim.com", "zendesk.io"]),
        ("Freshdesk", ["freshdesk.com", "freshchat.com", "freshworks.com", "freshrelevance.com"]),
        ("HelpScout", ["helpscout.net", "helpscout.com"]),
        ("Drift", ["drift.com", "driftt.com"]),
        ("Crisp", ["crisp.chat", "crisp.im"]),
        ("Salesforce", ["salesforce.com", "force.com", "salesforceliveagent.com", "my.salesforce.com", "documentforce.com"]),
        ("HubSpot", ["hubspot.com", "hs-scripts.com", "hsforms.com", "hubapi.com", "hs-analytics.net", "hscollectedforms.net"]),
        ("Klaviyo", ["klaviyo.com", "klaviyodata.com"]),
        ("Emarsys", ["emarsys.net", "emarsys.com", "scarabresearch.com"]),
        ("Insider", ["useinsider.com", "api.useinsider.com"]),
        ("WebEngage", ["webengage.com", "webengage.co"]),
        ("Netcore", ["netcoresmartech.com", "netcore.co.in"]),
        ("Unifonic", ["unifonic.com"]),

        // MARK: - Feature flags / config / experimentation

        ("LaunchDarkly", ["launchdarkly.com", "ldmwl.com"]),
        ("Optimizely", ["optimizely.com", "optimizelyapis.com"]),
        ("Split", ["split.io"]),
        ("Statsig", ["statsig.com", "statsigapi.net"]),
        ("ConfigCat", ["configcat.com"]),
        ("Unleash", ["getunleash.io", "unleash-hosted.com"]),
        ("Flagsmith", ["flagsmith.com"]),
        ("Apptimize", ["apptimize.com"]),
        ("Taplytics", ["taplytics.com"]),
        ("VWO", ["visualwebsiteoptimizer.com", "vwo.com"]),
        ("AB Tasty", ["abtasty.com"]),

        // MARK: - Ads / monetisation

        ("AppLovin", ["applovin.com", "applvn.com"]),
        ("ironSource", ["ironsrc.com", "ironsource.mobi", "supersonicads.com"]),
        ("Unity Ads", ["unityads.unity3d.com", "unity3d.com", "unityads.com"]),
        ("Vungle", ["vungle.com", "vungle.co"]),
        ("Chartboost", ["chartboost.com"]),
        ("AdColony", ["adcolony.com", "adtilt.com"]),
        ("Tapjoy", ["tapjoy.com", "tapjoyads.com"]),
        ("InMobi", ["inmobi.com", "inmobicdn.net"]),
        ("Criteo", ["criteo.com", "criteo.net"]),
        ("The Trade Desk", ["adsrvr.org", "thetradedesk.com"]),
        ("PubMatic", ["pubmatic.com"]),
        ("Rubicon", ["rubiconproject.com"]),
        ("OpenX", ["openx.net", "openx.com"]),
        ("Index Exchange", ["casalemedia.com", "indexexchange.com"]),
        ("Smaato", ["smaato.net", "smaato.com"]),
        ("Taboola", ["taboola.com"]),
        ("Outbrain", ["outbrain.com", "outbrainimg.com"]),
        ("MoPub", ["mopub.com"]),
        ("Liftoff", ["liftoff.io"]),
        ("Digital Turbine", ["digitalturbine.com", "fyber.com"]),
        ("Verve", ["verve.com", "pubnative.net"]),
        ("Prebid", ["prebid.org", "prebid.adnxs.com"]),
        ("AppNexus", ["adnxs.com", "appnexus.com"]),
        ("Moat", ["moatads.com", "moat.com"]),
        ("DoubleVerify", ["doubleverify.com", "dvtps.com"]),
        ("IAS", ["adsafeprotected.com", "integralads.com"]),

        // MARK: - Social

        ("Facebook", ["facebook.com", "fbcdn.net", "graph.facebook.com", "fb.com", "facebook.net", "fbsbx.com"]),
        ("Instagram", ["instagram.com", "cdninstagram.com"]),
        ("WhatsApp", ["whatsapp.com", "whatsapp.net"]),
        ("X (Twitter)", ["twitter.com", "x.com", "twimg.com", "t.co", "api.twitter.com"]),
        ("TikTok", ["tiktok.com", "tiktokv.com", "byteoversea.com", "tiktokcdn.com", "musical.ly", "bytedance.com"]),
        ("Snapchat", ["snapchat.com", "sc-static.net", "snap.com", "snapkit.com"]),
        ("LinkedIn", ["linkedin.com", "licdn.com", "bizographics.com"]),
        ("Pinterest", ["pinterest.com", "pinimg.com", "ct.pinterest.com"]),
        ("Reddit", ["reddit.com", "redd.it", "redditstatic.com", "redditmedia.com"]),
        ("Telegram", ["telegram.org", "t.me", "telegra.ph"]),
        ("Discord", ["discord.com", "discordapp.com", "discord.gg"]),
        ("Slack", ["slack.com", "slack-edge.com", "slack-msgs.com"]),
        ("VK", ["vk.com", "vk-cdn.net", "userapi.com"]),
        ("Weibo", ["weibo.com", "sinaimg.cn"]),
        ("WeChat", ["weixin.qq.com", "wechat.com", "qq.com"]),
        ("Line", ["line.me", "line-apps.com", "line-scdn.net"]),
        ("Kakao", ["kakao.com", "kakaocdn.net", "daumcdn.net"]),

        // MARK: - Maps / location / geo

        ("Mapbox", ["mapbox.com", "tiles.mapbox.com", "api.mapbox.com"]),
        ("HERE", ["here.com", "hereapi.com", "ls.hereapi.com"]),
        ("TomTom", ["tomtom.com", "api.tomtom.com"]),
        ("OpenStreetMap", ["openstreetmap.org", "tile.openstreetmap.org"]),
        ("Foursquare", ["foursquare.com", "foursquareapi.com"]),
        ("ipify", ["ipify.org"]),
        ("ipinfo", ["ipinfo.io"]),
        ("MaxMind", ["maxmind.com"]),
        ("ip-api", ["ip-api.com"]),
        ("Radar", ["radar.io"]),
        ("What3words", ["what3words.com"]),

        // MARK: - Media / CDN / images

        ("Cloudinary", ["cloudinary.com", "res.cloudinary.com"]),
        ("imgix", ["imgix.net", "imgix.com"]),
        ("Akamai", ["akamai.net", "akamaized.net", "akamaihd.net", "akamaiedge.net", "edgekey.net", "edgesuite.net"]),
        ("Fastly", ["fastly.net", "fastlylb.net", "fastly.com"]),
        ("Cloudflare", ["cloudflare.com", "cloudflare.net", "cdnjs.cloudflare.com", "workers.dev", "cf-ipfs.com", "cloudflareinsights.com", "cloudflarestream.com"]),
        ("jsDelivr", ["jsdelivr.net"]),
        ("unpkg", ["unpkg.com"]),
        ("Bunny CDN", ["b-cdn.net", "bunnycdn.com", "bunny.net"]),
        ("KeyCDN", ["kxcdn.com", "keycdn.com"]),
        ("StackPath", ["stackpathcdn.com", "stackpathdns.com"]),
        ("Imgur", ["imgur.com", "i.imgur.com"]),
        ("Unsplash", ["unsplash.com", "images.unsplash.com"]),
        ("Giphy", ["giphy.com", "giphy.net"]),
        ("Mux", ["mux.com", "litix.io", "mux.dev"]),
        ("JW Player", ["jwplayer.com", "jwpcdn.com", "jwpsrv.com"]),
        ("Brightcove", ["brightcove.com", "brightcove.net", "bcovlive.io"]),
        ("Vimeo", ["vimeo.com", "vimeocdn.com"]),
        ("Wistia", ["wistia.com", "wistia.net", "wi.st"]),
        ("Kaltura", ["kaltura.com", "kaltura.org"]),
        ("Agora", ["agora.io", "agoraio.cn"]),
        ("Daily", ["daily.co"]),
        ("Twitch", ["twitch.tv", "ttvnw.net", "jtvnw.net"]),
        ("Spotify", ["spotify.com", "scdn.co", "spotifycdn.com"]),
        ("SoundCloud", ["soundcloud.com", "sndcdn.com"]),
        ("Netflix", ["netflix.com", "nflxvideo.net", "nflximg.net"]),

        // MARK: - Commerce platforms

        ("Shopify", ["shopify.com", "myshopify.com", "shopifycdn.com", "shopifysvc.com", "shopifycloud.com", "shopifyapps.com"]),
        ("Salla", ["salla.sa", "salla.dev", "salla.network", "salla.com", "salla.link"]),
        ("Zid", ["zid.sa", "zid.store"]),
        ("WooCommerce", ["woocommerce.com"]),
        ("BigCommerce", ["bigcommerce.com", "mybigcommerce.com"]),
        ("Magento", ["magento.com", "magentocommerce.com"]),
        ("Wix", ["wix.com", "wixstatic.com", "parastorage.com", "wixapps.net"]),
        ("Squarespace", ["squarespace.com", "sqspcdn.com", "squarespace-cdn.com"]),
        ("Etsy", ["etsy.com", "etsystatic.com"]),
        ("eBay", ["ebay.com", "ebaystatic.com", "ebayimg.com"]),
        ("Alibaba", ["alibaba.com", "aliexpress.com", "alicdn.com", "aliyuncs.com"]),
        ("Noon", ["noon.com", "nooncdn.com"]),
        ("Jumia", ["jumia.com", "jumia.com.ng"]),
        ("Souq", ["souq.com"]),
        ("Talabat", ["talabat.com"]),
        ("Careem", ["careem.com"]),
        ("HungerStation", ["hungerstation.com"]),
        ("Jahez", ["jahez.net"]),
        ("Mrsool", ["mrsool.co"]),

        // MARK: - Identity / auth

        ("Auth0", ["auth0.com", "eu.auth0.com", "us.auth0.com"]),
        ("Okta", ["okta.com", "oktacdn.com", "oktapreview.com"]),
        ("Firebase Auth", ["identitytoolkit.googleapis.com", "securetoken.googleapis.com"]),
        ("Clerk", ["clerk.dev", "clerk.com", "clerk.accounts.dev"]),
        ("Supertokens", ["supertokens.com", "supertokens.io"]),
        ("Keycloak", ["keycloak.org"]),
        ("Ping Identity", ["pingidentity.com", "pingone.com"]),
        ("OneLogin", ["onelogin.com"]),
        ("Nafath", ["nafath.sa", "iam.gov.sa"]),
        ("Absher", ["absher.sa"]),

        // MARK: - Backend / BaaS / database

        ("Supabase", ["supabase.co", "supabase.com", "supabase.in"]),
        ("Appwrite", ["appwrite.io"]),
        ("Parse", ["parseapi.back4app.com", "back4app.com", "parseplatform.org"]),
        ("MongoDB", ["mongodb.com", "mongodb.net", "realm.mongodb.com"]),
        ("Redis", ["redis.com", "redislabs.com", "upstash.io"]),
        ("PlanetScale", ["planetscale.com", "psdb.cloud"]),
        ("Neon", ["neon.tech"]),
        ("Hasura", ["hasura.app", "hasura.io"]),
        ("Prisma", ["prisma.io"]),
        ("Fauna", ["fauna.com", "faunadb.com"]),
        ("Xano", ["xano.io", "xano.com"]),
        ("Directus", ["directus.app", "directus.io"]),
        ("Strapi", ["strapi.io", "strapiapp.com"]),
        ("Contentful", ["contentful.com", "ctfassets.net"]),
        ("Sanity", ["sanity.io", "apicdn.sanity.io"]),
        ("Prismic", ["prismic.io", "cdn.prismic.io"]),
        ("Storyblok", ["storyblok.com"]),
        ("Ghost", ["ghost.io", "ghost.org"]),
        ("WordPress", ["wordpress.com", "wp.com", "wordpress.org", "gravatar.com"]),

        // MARK: - Hosting / PaaS

        ("Vercel", ["vercel.app", "vercel.com", "now.sh", "vercel-insights.com"]),
        ("Netlify", ["netlify.app", "netlify.com", "netlifyglobalcdn.com"]),
        ("Heroku", ["herokuapp.com", "heroku.com"]),
        ("Render", ["onrender.com", "render.com"]),
        ("Railway", ["railway.app", "up.railway.app"]),
        ("Fly.io", ["fly.dev", "fly.io"]),
        ("DigitalOcean", ["digitaloceanspaces.com", "digitalocean.com", "ondigitalocean.app"]),
        ("Linode", ["linode.com", "linodeobjects.com"]),
        ("Cloudflare Pages", ["pages.dev"]),
        ("GitHub Pages", ["github.io"]),
        ("Firebase Hosting", ["web.app"]),
        ("ngrok", ["ngrok.io", "ngrok.app", "ngrok-free.app"]),
        ("localhost tunnels", ["loca.lt", "serveo.net", "localtunnel.me", "trycloudflare.com"]),

        // MARK: - Developer platforms

        ("GitHub", ["github.com", "githubusercontent.com", "githubassets.com", "api.github.com", "ghcr.io"]),
        ("GitLab", ["gitlab.com", "gitlab.io"]),
        ("Bitbucket", ["bitbucket.org", "bitbucket.io"]),
        ("npm", ["npmjs.com", "npmjs.org", "registry.npmjs.org"]),
        ("PyPI", ["pypi.org", "pythonhosted.org"]),
        ("Maven Central", ["maven.org", "sonatype.org", "mvnrepository.com"]),
        ("CocoaPods", ["cocoapods.org", "cdn.cocoapods.org"]),
        ("Swift Package Index", ["swiftpackageindex.com"]),
        ("Docker Hub", ["docker.io", "docker.com"]),
        ("Jira", ["atlassian.net", "atlassian.com", "jira.com"]),
        ("Sentry CDN", ["sentry-cdn.com", "sentry-cdn.net"]),
        ("Bitrise", ["bitrise.io"]),
        ("CircleCI", ["circleci.com"]),
        ("Codecov", ["codecov.io"]),
        ("Firebase App Distribution", ["firebaseappdistribution.googleapis.com"]),

        // MARK: - AI / ML

        ("Anthropic", ["anthropic.com", "api.anthropic.com", "claude.ai"]),
        ("OpenAI", ["openai.com", "api.openai.com", "oaistatic.com", "chatgpt.com"]),
        ("Hugging Face", ["huggingface.co", "hf.co"]),
        ("Replicate", ["replicate.com", "replicate.delivery"]),
        ("Cohere", ["cohere.ai", "cohere.com"]),
        ("Mistral", ["mistral.ai"]),
        ("Perplexity", ["perplexity.ai"]),
        ("Groq", ["groq.com"]),
        ("Together AI", ["together.ai", "together.xyz"]),
        ("ElevenLabs", ["elevenlabs.io"]),
        ("Stability AI", ["stability.ai"]),
        ("Pinecone", ["pinecone.io"]),
        ("Weaviate", ["weaviate.io", "weaviate.network"]),
        ("LangSmith", ["langchain.com", "smith.langchain.com"]),
        ("Google Gemini", ["generativelanguage.googleapis.com", "aistudio.google.com"]),

        // MARK: - Productivity / SaaS

        ("Notion", ["notion.so", "notion.com", "notion.site"]),
        ("Airtable", ["airtable.com", "airtableusercontent.com"]),
        ("Figma", ["figma.com", "figma-alpha-api.s3.us-west-2.amazonaws.com"]),
        ("Dropbox", ["dropbox.com", "dropboxapi.com", "dropboxusercontent.com"]),
        ("Box", ["box.com", "boxcloud.com"]),
        ("Zoom", ["zoom.us", "zoom.com", "zoomgov.com"]),
        ("Asana", ["asana.com"]),
        ("Trello", ["trello.com", "trellocdn.com"]),
        ("Monday", ["monday.com"]),
        ("Miro", ["miro.com", "realtimeboard.com"]),
        ("Calendly", ["calendly.com"]),
        ("Typeform", ["typeform.com"]),
        ("SurveyMonkey", ["surveymonkey.com"]),
        ("DocuSign", ["docusign.com", "docusign.net"]),

        // MARK: - Security / anti-fraud / consent

        ("hCaptcha", ["hcaptcha.com"]),
        ("Cloudflare Turnstile", ["challenges.cloudflare.com"]),
        ("Arkose Labs", ["arkoselabs.com", "funcaptcha.com"]),
        ("PerimeterX", ["perimeterx.net", "px-cdn.net", "px-cloud.net"]),
        ("DataDome", ["datadome.co", "captcha-delivery.com"]),
        ("Sift", ["sift.com", "siftscience.com"]),
        ("Forter", ["forter.com"]),
        ("Riskified", ["riskified.com"]),
        ("Seon", ["seon.io"]),
        ("Fingerprint", ["fpjs.io", "fingerprintjs.com", "fpapi.io"]),
        ("OneTrust", ["onetrust.com", "cookielaw.org", "otsdk.com", "cookiepro.com"]),
        ("Usercentrics", ["usercentrics.eu", "usercentrics.com"]),
        ("Didomi", ["didomi.io"]),
        ("Quantcast Choice", ["quantcast.mgr.consensu.org"]),
        ("Have I Been Pwned", ["haveibeenpwned.com", "api.pwnedpasswords.com"]),
        ("VirusTotal", ["virustotal.com"]),
        ("Let's Encrypt", ["letsencrypt.org", "acme-v02.api.letsencrypt.org"]),
        ("OCSP", ["ocsp.digicert.com", "ocsp.sectigo.com", "ocsp.apple.com"]),

        // MARK: - Delivery / logistics / travel

        ("Uber", ["uber.com", "uberinternal.com", "uber-assets.com"]),
        ("Lyft", ["lyft.com"]),
        ("DoorDash", ["doordash.com", "doordashcdn.com"]),
        ("Deliveroo", ["deliveroo.com", "deliveroo.co.uk"]),
        ("Aramex", ["aramex.com"]),
        ("DHL", ["dhl.com", "dhl.de"]),
        ("FedEx", ["fedex.com"]),
        ("UPS", ["ups.com"]),
        ("SMSA", ["smsaexpress.com"]),
        ("Shipa", ["shipa.com"]),
        ("Booking.com", ["booking.com", "bstatic.com"]),
        ("Airbnb", ["airbnb.com", "muscache.com"]),
        ("Expedia", ["expedia.com", "trvl-media.com"]),
        ("Skyscanner", ["skyscanner.net", "skyscanner.com"]),
        ("Amadeus", ["amadeus.com", "api.amadeus.com"]),
        ("Sabre", ["sabre.com"]),

        // MARK: - Finance / data

        ("Bloomberg", ["bloomberg.com"]),
        ("Yahoo Finance", ["yahoo.com", "yimg.com", "query1.finance.yahoo.com"]),
        ("Alpha Vantage", ["alphavantage.co"]),
        ("Finnhub", ["finnhub.io"]),
        ("Polygon.io", ["polygon.io"]),
        ("CoinGecko", ["coingecko.com"]),
        ("CoinMarketCap", ["coinmarketcap.com"]),
        ("Binance", ["binance.com", "binance.us"]),
        ("Open Exchange Rates", ["openexchangerates.org"]),
        ("Fixer", ["fixer.io"]),
        ("Currencylayer", ["currencylayer.com"]),

        // MARK: - Weather / utility APIs

        ("OpenWeather", ["openweathermap.org"]),
        ("WeatherAPI", ["weatherapi.com"]),
        ("AccuWeather", ["accuweather.com"]),
        ("Dark Sky", ["darksky.net"]),
        ("REST Countries", ["restcountries.com"]),
        ("JSONPlaceholder", ["jsonplaceholder.typicode.com", "typicode.com"]),
        ("httpbin", ["httpbin.org"]),
        ("Postman Echo", ["postman-echo.com", "getpostman.com", "postman.com"]),
        ("ReqRes", ["reqres.in"]),
        ("Mocky", ["mocky.io"]),
        ("WorldTimeAPI", ["worldtimeapi.org"]),
        ("NASA", ["api.nasa.gov", "nasa.gov"]),
        ("OpenAQ", ["openaq.org"]),

        // MARK: - Localisation / content

        ("Lokalise", ["lokalise.com", "lokalise.co"]),
        ("Phrase", ["phrase.com", "phraseapp.com"]),
        ("Crowdin", ["crowdin.com"]),
        ("Transifex", ["transifex.com"]),
        ("DeepL", ["deepl.com"]),
        ("Google Translate", ["translate.googleapis.com", "translate.google.com"]),

        // MARK: - Testing / QA / release

        ("Firebase Test Lab", ["testing.googleapis.com"]),
        ("BrowserStack", ["browserstack.com"]),
        ("Sauce Labs", ["saucelabs.com"]),
        ("Applitools", ["applitools.com"]),
        ("Maestro", ["mobile.dev"]),

        // MARK: - Regional / telecom / government (MENA-heavy, matches this SDK's users)

        ("STC", ["stc.com.sa"]),
        ("Mobily", ["mobily.com.sa"]),
        ("Zain", ["sa.zain.com", "zain.com"]),
        ("Etisalat", ["etisalat.ae"]),
        ("Du", ["du.ae"]),
        ("Elm", ["elm.sa"]),
        ("Yakeen", ["yakeen.sa"]),
        ("SDAIA", ["sdaia.gov.sa"]),
        ("Saudi Post", ["splonline.com.sa", "sp.com.sa"]),
        ("Tawuniya", ["tawuniya.com.sa"]),
        ("Bupa", ["bupa.com.sa"]),
        ("Al Rajhi", ["alrajhibank.com.sa"]),
        ("SNB", ["alahli.com", "snb.com.sa"]),
        ("Riyad Bank", ["riyadbank.com"]),

        // MARK: - Misc well-known

        ("Wikipedia", ["wikipedia.org", "wikimedia.org", "wikidata.org"]),
        ("Gravatar", ["secure.gravatar.com"]),
        ("Adobe", ["adobe.com", "adobedtm.com", "omtrdc.net", "demdex.net", "typekit.net", "2o7.net"]),
        ("Oracle", ["oracle.com", "oraclecloud.com", "responsys.net", "eloqua.com"]),
        ("SAP", ["sap.com", "hana.ondemand.com"]),
        ("IBM", ["ibm.com", "bluemix.net", "watsonplatform.net"]),
        ("Samsung", ["samsung.com", "samsungapps.com", "samsungcloud.com"]),
        ("Huawei", ["huawei.com", "hicloud.com", "dbankcdn.com"]),
        ("Xiaomi", ["xiaomi.com", "mi.com", "miui.com"]),
        ("Baidu", ["baidu.com", "bdstatic.com"]),
        ("Tencent", ["tencent.com", "qcloud.com", "myqcloud.com"]),
        ("Cloudflare DNS", ["one.one.one.one"]),
        ("Mozilla", ["mozilla.org", "mozilla.com", "mozilla.net"]),
    ]

    // MARK: - Lookup

    /// The catalog label for `host`, or nil when nothing in the catalog is a
    /// dot-boundary suffix of it.
    ///
    /// Walks label-by-label from the most specific form to the least, so a host
    /// that has its own entry never loses to its parent domain's entry.
    static func label(forHost host: String) -> String? {
        let normalized = normalizeHost(host)
        guard !normalized.isEmpty else { return nil }

        // Whole host first, then drop one leading label at a time.
        // "firebaselogging-pa.googleapis.com" -> "googleapis.com" -> "com"
        var candidate = Substring(normalized)
        while true {
            if let label = entries[String(candidate)] { return label }
            guard let dot = candidate.firstIndex(of: ".") else { return nil }
            candidate = candidate[candidate.index(after: dot)...]
            // A bare TLD ("com") can never be a meaningful match and is not in
            // the table, but stopping here saves a pointless final lookup.
            if !candidate.contains(".") { return entries[String(candidate)] }
        }
    }

    /// Strips a `www.` prefix, a trailing dot and a port, and lowercases —
    /// the forms a `URL.host` can legitimately take that would otherwise miss.
    static func normalizeHost(_ host: String) -> String {
        var value = host.lowercased().trimmingCharacters(in: .whitespaces)

        // An IPv6 literal is bracketed and full of colons, so the port strip
        // below would cut it down to "[" — a non-empty "host" that then became a
        // tag of its own, lumping every IPv6 request together under it. Keep the
        // literal whole and take the port only from after the closing bracket.
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]") else { return value }
            return String(value[value.startIndex...close])
        }

        if let colon = value.firstIndex(of: ":") { value = String(value[value.startIndex..<colon]) }
        while value.hasSuffix(".") { value.removeLast() }
        if value.hasPrefix("www.") { value = String(value.dropFirst(4)) }
        return value
    }
}
