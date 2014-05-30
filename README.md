## XprobePlugin - Objective-C App Memory Browser

The XprobePlugin gives you a view of the objects inside your application either
in detail down to the level of ivars or globally as a graph of the principal objects
and how they are connected, highlighting objects as they are messaged in real time.
This is done automatically by performing a "sweep" to find all objects referred to
by a set of seeds, the objects they refer to, the objects those refer to and so 
forth to build up the list of live objects which can be displayed as a graph:

![Icon](http://injectionforxcode.johnholdsworth.com/xprobe2.png)

In the simulator, the memory sweeper is loaded from a bundle inside the plugin using lldb
requiring no changes to the app's project source. To use the plugin, build this project
and restart Xcode. Once your application running, use menu item "Product/Xprobe/Load"
to load the initial view of the  memory sweep of your app, you can then filter the
objects listed by classname.

The remaining features are nost easilly described by a series of bullet points:

![Icon](http://injectionforxcode.johnholdsworth.com/xprobe1.png)

Click on an object's link to view it's ivar contents.

Click the link again to close the detail view.

Click on the superclass link to view it's ivars

Click on an ivar name to update it's value from the app

Click on an ivar value to edit it and set it's value in the app

The class' properties, methods and any protocols can be viewed.

The method lists can be searched (including any superclass methods matching)

Use the "trace" link to start logging all calls to that class' methods on that instance.

Trace output can be filtrered using a regular expression

The subviews link will recursively display the tree of subviews under a view.

The "render" link will display a captured image when the object is a view.

The siblings link will display all objects found that share the object's class.

Refresh the object list by typing enter in the Search Feild to force a new sweep.

Pressing the Graph button will open the summary view of the most important objects
and any "kit" objects directly linked to them taken from the last sweep.

Graph display requires an installation of ["Graphviz/dot"](http://www.graphviz.org/) on your computer.

Click on an object to view it's current contents as discussed above.

Differing filtering of which objects to include can be applied.

"Animate Messages" puts a trace on objects having them display "red" when messaged.

Graphs can be exported to Graphviz or .png format for printing.

Thats about it.

### Use on a device.

Xprobe works by loading a bundle in the simulator which connects to Xcode when it is loaded.
An application makes its list of seed nodes known to Xprobe by implementing the following category:

    @implementation Xprobe(Seeding)

    + (NSArray *)xprobeSeeds {
        UIApplication *app = [UIApplication sharedApplication];
        NSMutableArray *seeds = [[app windows] mutableCopy];
        [roots insertObject:app atIndex:0];

        // support for cocos2d
        Class ccDirectorClass = NSClassFromString(@"CCDirector");
        CCDirector *ccDirector = [ccDirectorClass sharedDirector];
        if ( ccDirector )
            [seeds addObject:ccDirector];
        return seeds;
    }

    @end
    
Once an app is initialised call [Xprobe connectTo:"your.ip.address" retainObjects:YES] to
connect to the TCP server running inside Xcode. The retainObjects: argument specifies whether
to retain objects found in the sweep. This will make Xprobe more reliable but it will affect
object lifecyles in your app. After this, call [Xprobe search:@""] to perform the initial sweep 
starting at these objects looking for root objects. Each time "search:" is called or the object 
class filter is changed the sweep is performed anew. The application will need to be built with
Xprobe and Xtrace.{h,mm}.

In this day and age of nice clean strong and weak pointers the sweep seems very reliable
if objects are somehow visible to the seeds. Some legacy classes are not well behaved and 
use "assign" properties which can contain pointers to deallocated objects. To avoid 
sweeping the ivars of these classes Xprobe has an exclusion filter which can be overridden 
(with a warning) in a category:

    @implementation Xprobe(ExclusionOverride)

    + (BOOL)xprobeExclude:(const char *)className {
        return className[0] == '_' || strncmp(className, "WebHistory", 10) == 0 ||
            strncmp(className, "NS", 2) == 0 || strncmp(className, "XC", 2) == 0 ||
            strncmp(className, "IDE", 3) == 0 || strncmp(className, "DVT", 3) == 0 ||
            strncmp(className, "Xcode3", 6) == 0 ||strncmp(className, "IB", 2) == 0;
    }
    
    @end
    
These exclusions allow Xprobe to work cleanly inside Xcode itself which comes in handy 
if you're a plugin dev. For any suggestions or feedback you can contact the author
on xprobe at johnholdsworth.com. Major releases will be announced on twitter
[@Injection4Xcode](https://twitter.com/#!/@Injection4Xcode).

### License

Copyright (c) 2014 John Holdsworth. Licensed for any use during development of Objective-C
applications, re-distribution may only be through github however including this copyright notice.

This release includes a very slightly modifed version of the excellent 
[canviz](https://code.google.com/p/canviz/) library to render "dot" files 
in an HTML canvas which is subject to an MIT license. The changes are to pass 
through the ID of the node to the node label tag (line 208) and to reverse 
the rendering of nodes and the lines linking them on (line 406) in "canviz-0.1/canviz.js".

### As ever:

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT 
LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. 
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, 
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE 
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
