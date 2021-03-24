## ![Icon](http://injectionforxcode.johnholdsworth.com/swiss1.jpg)  Xprobe Realtime Memory Browser

**Update:** This former Xcode plugin has been re-organised into a
Swift Package for use in other apps. Use the `Xprobe` product in
client applications and the `XprobeUI` product at the server side.

The XprobePlugin gives you a view of the objects inside your application either
in detail down to the level of ivars or globally as a graph of the principal objects
and how they are connected. This display can be animated in real time, highlighting in
red objects as they are messaged and the paths down which messages are flowing.
This is done automatically by performing a "sweep" to find all objects referred to
by a set of seeds, the objects they refer to, the objects those refer to and so 
forth to build up the list of live objects which can be displayed in Xcode:

![Icon](http://johnholdsworth.com/mirror.gif)

In the simulator, the memory sweeper is loaded from a bundle inside the plugin using lldb
requiring no changes to the app's project source. To use the plugin, build this project
and restart Xcode. Once your application is running, use menu item "Product/Xprobe/Load"
to load the initial view of the  memory sweep of your app. If you are a plugin developer
you use "Product/Xprobe/Xcode" to inspect the objects of the Xcode application itself.

You can then filter the objects listed into the app or their methods using a pattern.
If there are no objects matching the pattern and it is a class name it will be displayed.
Patterns prefixed with '+' or '-' will search all classes linked into the
application for methods matching the pattern. A raw pointer prefixed with
"0x" can be entered to inspect an object passed as an argument to a trace.
You can also enter an object "path" starting "seed." from the paths logged
as you browse your application so you can find your way back to objects
easily.

If you have the [injectionforxcode](https://github.com/johnno1962/injectionforxcode) plugin
installed Xprobe will allow you to evaluate Objective-C or Swift against a selected instance
for which you have the source to log or modify any aspect of the object's state at run time.

#### Stop Press: 

Xprobe.mm can now snapshot your app to a standalone html file in the event of an error.
This performs a sweep and can document the state of your app at the time the error occured
for later analysis. An example snapshot file for a ReactNative example project
"TickTackToe" can be [viewed here](http://johnholdsworth.com/snapshot.html).

 To take a snapshot, include Xprobe.mm in your app and use the following call:

```objc
    [Xprobe snapshot:@"/path/to/snapshot.html.gz" seeds:@[app delegate, rootViewController]];
```

If you run into difficulties you can alter the pattern of classe names not to capture with
an additional excluding:(NSString *)pattern argument. The default value for this is:

```objc
    @"^(?:UI|NS((Object|URL|Proxy)$|Text|Layout|Index|.*(Map|Data|Font))|Web|WAK|SwiftObject|XC|IDE|DVT|Xcode3|IB|VK)"
```

The remaining features are most easily rolled off as a series of bullet points:

![Icon](http://injectionforxcode.johnholdsworth.com/xprobe1.png)

Click on an object's link to view it's ivar contents.

Click the link again to close the detail view.

Click on the superclass link to view it's ivars

Click on an ivar name to refresh it's value from the app

Click on an ivar value to edit and set it's value in the app

The class' properties, methods and any protocols can be viewed.

The method lists can be searched (also finding superclass methods)

Use the "trace" link to start logging calls to methods on that instance.

To see all methods traced for an object, click trace against each class.

Trace output can be filtered using a regular expression

The subviews link will recursively display the tree of subviews under a view.

The "render" link will capture an image when the object is a view.

The siblings link will display all objects found that share the object's class.

Refresh the object list by typing enter in the Search Field to force a new sweep.

Pressing the Graph button will open the summary view of the most important objects
and any "kit" objects directly linked to them taken from the last sweep.

The object is represented as a square if is it a view (responds to "subviews".)

Graph display requires an installation of ["Graphviz/dot"](http://www.graphviz.org/) on your computer.

Click on an object to view it's current contents as discussed above.

Differing filtering of which objects to include can be applied.

"Animate Messages" puts a trace on objects having them display "red" when messaged.

Graphs can be exported to Graphviz or .png format for printing.

Alas, Swift support is limited at the moment as ivar_getTypeEncoding() returns 
NULL for ivar fields preventing them taking part in the "sweep".

### Use on a device.

Xprobe works by loading a bundle in the simulator which connects to Xcode when it is loaded.
An application makes its list of seed nodes known to Xprobe by implementing the following category:

```objc
    @implementation Xprobe(Seeding)

    + (NSArray *)xprobeSeeds {
        UIApplication *app = [UIApplication sharedApplication];
        NSMutableArray *seeds = [NSMutableArray arrayWithObject:app];
        [seeds addObjectsFromArray:[app windows]];

        // support for cocos2d
        Class ccDirectorClass = NSClassFromString(@"CCDirector");
        CCDirector *ccDirector = [ccDirectorClass sharedDirector];
        if ( ccDirector )
            [seeds addObject:ccDirector];

        return seeds;
    }

    @end
```

Or for OSX:

```objc
    + (NSArray *)xprobeSeeds {
        NSApplication *app = [NSApplication sharedApplication];
        NSMutableArray *seeds = [[app windows] mutableCopy];
        if ( app.delegate )
            [seeds insertObject:app.delegate atIndex:0];
        return seeds;
    }
```

Once an app is initialised call [Xprobe connectTo:"your.ip.address" retainObjects:YES] to
connect to the TCP server running inside Xcode. The retainObjects: argument specifies whether
to retain objects found in the sweep. This will make Xprobe more reliable but it will affect
object life-cycles in your app. After this, call [Xprobe search:@""] to perform the initial sweep 
starting at these objects looking for root objects. Each time "search:" is called or the object 
class filter is changed the sweep is performed anew. The application will need to be built with
Xprobe and Xtrace.{h,mm}.

In this day and age of nice clean "strong" and "weak" pointers the sweep seems very reliable
if objects are somehow visible to the seeds. Some legacy classes are not well behaved and 
use "assign" properties which can contain pointers to deallocated objects. To avoid 
sweeping the ivars of these classes Xprobe has an exclusion filter which can be overridden 
(with a warning) in a category:

```objc
    static NSString *swiftPrefix = @"_TtC";

    @implementation Xprobe(ExclusionOverride)

    + (BOOL)xprobeExclude:(NSString *)className {
        static NSRegularExpression *excluded;
        if ( !excluded )
            excluded = [NSRegularExpression xsimpleRegexp:@"^(_|NS|XC|IDE|DVT|Xcode3|IB|VK|WebHistory)"];
        return [excluded xmatches:className] && ![className hasPrefix:swiftPrefix];
    }
    
    @end
```

These exclusions allow Xprobe to work cleanly inside Xcode itself which comes in handy 
if you're a plugin dev. For any suggestions or feedback you can contact the author
on xprobe at johnholdsworth.com. Major releases will be announced on twitter
[@Injection4Xcode](https://twitter.com/#!/@Injection4Xcode).

With Swift 2.3+, Xprobe is no longer able to scan ivars that do not have properties
i.e. classes that do not inherit from NSObject.

### Source files

Xprobe.{h,mm} - core Xprobe functionality required for snapshots
IvarAccess.h - required routines for access to class ivars by name
Xprobe+Service.mm - optional interactive service connecting to Xcode

### License

Copyright (c) 2014-5 John Holdsworth. Licensed for download, modification and any use during development
of Objectice-C applications, re-distribution may only be through a public repo github however including
this copyright notice. For binary redistribution with your app [get in touch](mailto:xprobe@johnholdsworth.com)!

This release includes a very slightly modified version of the excellent 
[canviz](https://code.google.com/p/canviz/) library to render "dot" files 
in an HTML canvas which is subject to an MIT license. The changes are to pass 
through the ID of the node to the node label tag (line 212), to reverse
the rendering of nodes and the lines linking them (line 406) and to
store edge paths so they can be colored (line 66 and 303) in "canviz-0.1/canviz.js".

It now also includes [CodeMirror](http://codemirror.net/) JavaScript editor
for the code to be evaluated using injection under an MIT license.

### As ever:

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT 
LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. 
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, 
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE 
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
