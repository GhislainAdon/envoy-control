@file:Suppress("MagicNumber")

package pl.allegro.tech.servicemesh.envoycontrol.consul

import java.time.Duration

class ConsulProperties {
    var host: String = "localhost"
    var port = 8500
    var subscriptionDelay: Duration = Duration.ofMillis(20) // max 50 subscription/s
    var watcher = ConsulWatcherOkHttpProperties()
}

class ConsulWatcherOkHttpProperties {
    var readTimeout: Duration = Duration.ofMinutes(6)
    var connectTimeout: Duration = Duration.ofSeconds(2)
    var maxRequests = 1000
    var dispatcherMaxPoolSize = 2000
    var dispatcherPoolKeepAliveTime: Duration = Duration.ofSeconds(30)
}
