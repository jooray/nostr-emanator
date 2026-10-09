package today.cypherpunk.emanator

import android.app.Application
import coil3.SingletonImageLoader

class EmanatorApplication : Application(), SingletonImageLoader.Factory {
    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        container = AppContainer(this)
    }

    override fun newImageLoader(context: coil3.PlatformContext) = container.imageLoader
}
