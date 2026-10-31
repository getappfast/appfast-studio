import Foundation
import Testing
@testable import Mobile_Studio

struct FlowFinderTests {
    private func flow(_ files: [String: String]) -> AppFlow {
        FlowFinder.flow(sources: files.map { DartSource(file: $0.key, text: $0.value) }, folder: "/app")
    }

    private func links(_ flow: AppFlow) -> Set<String> {
        Set(flow.links.map { "\($0.from) \($0.kind) \($0.to)" })
    }

    @Test func followsNavigatorPushFromAScreenAndItsState() {
        let flow = flow([
            "lib/main.dart": "class MyApp extends StatelessWidget { build(c) => MaterialApp(home: const HomePage()); }",
            "lib/home_page.dart": """
            class HomePage extends StatefulWidget {}
            class _HomePageState extends State<HomePage> {
              void open() {
                Navigator.push(context, MaterialPageRoute(builder: (_) => const ProfilePage()));
              }
            }
            """,
            "lib/profile_page.dart": """
            class ProfilePage extends StatelessWidget {
              build(context) => IconButton(onPressed: () => Navigator.of(context).pushReplacement(
                MaterialPageRoute(builder: (_) => SettingsPage())));
            }
            """,
            "lib/settings_page.dart": "class SettingsPage extends StatelessWidget {}",
        ])
        #expect(flow.start == "HomePage")
        #expect(links(flow) == ["HomePage opens ProfilePage", "ProfilePage replaces SettingsPage"])
        #expect(flow.layout.columns == [["HomePage"], ["ProfilePage"], ["SettingsPage"]])
    }

    @Test func resolvesNamedRoutesThroughConstants() {
        let flow = flow([
            "lib/routes.dart": """
            class Routes { static const profile = '/profile'; static const settings = '/settings'; }
            final routes = {
              '/': (context) => const HomeScreen(),
              Routes.profile: (context) => const ProfileScreen(),
              Routes.settings: (_) { return SettingsScreen(); },
            };
            """,
            "lib/home.dart": """
            class HomeScreen extends StatelessWidget {
              tap(c) => Navigator.pushNamed(c, Routes.profile);
            }
            """,
            "lib/profile.dart": """
            class ProfileScreen extends StatelessWidget {
              tap(context) => Navigator.of(context).pushNamed('/settings');
            }
            """,
            "lib/settings.dart": "class SettingsScreen extends StatelessWidget {}",
        ])
        #expect(flow.start == "HomeScreen")
        #expect(links(flow) == ["HomeScreen opens ProfileScreen", "ProfileScreen opens SettingsScreen"])
    }

    @Test func readsGoRouterPathsNamesAndParameters() {
        let flow = flow([
            "lib/router.dart": """
            final router = GoRouter(initialLocation: '/login', routes: [
              GoRoute(path: '/login', builder: (context, state) => const LoginPage()),
              GoRoute(path: '/home', name: 'home', builder: (context, state) => const HomePage(), routes: [
                GoRoute(path: 'item/:id', builder: (context, state) => ItemPage(id: state.pathParameters['id']!)),
              ]),
            ]);
            """,
            "lib/login_page.dart": "class LoginPage extends StatelessWidget { done(ctx) => GoRouter.of(ctx).goNamed('home'); }",
            "lib/home_page.dart": "class HomePage extends StatelessWidget { open(c, id) => c.push('/home/item/$id'); }",
            "lib/item_page.dart": "class ItemPage extends StatelessWidget {}",
        ])
        #expect(flow.start == "LoginPage")
        #expect(links(flow) == ["LoginPage replaces HomePage", "HomePage opens ItemPage"])
    }

    @Test func countsTabsAsShownInsideAndWidgetsAsTheScreens() {
        let flow = flow([
            "lib/shell.dart": """
            class ShellPage extends StatefulWidget {}
            class _ShellPageState extends State<ShellPage> {
              final pages = [const FeedPage(), const ProfilePage()];
              build(context) => Scaffold(drawer: const AppDrawer(), body: pages[index]);
            }
            class AppDrawer extends StatelessWidget {
              build(context) => ListTile(onTap: () => context.router.push(SettingsRoute()));
            }
            """,
            "lib/pages.dart": """
            class FeedPage extends StatelessWidget {}
            class ProfilePage extends StatelessWidget {}
            class SettingsPage extends StatelessWidget {}
            """,
        ])
        #expect(links(flow) == ["ShellPage contains FeedPage", "ShellPage contains ProfilePage", "ShellPage opens SettingsPage"])
        #expect(flow.layout.columns == [["ShellPage"], ["FeedPage", "ProfilePage", "SettingsPage"]])
    }

    @Test func creditsAStateClassWithACustomBase() {
        let flow = flow([
            "lib/splash_screen.dart": """
            class SplashScreen extends StatefulWidget {}
            class _SplashScreenState extends ViewModel<SplashScreen, OnboardingCubit, OnboardingState> {
              void listener() { Navigator.of(context).pushReplacementNamed('/home'); }
            }
            """,
            "lib/main.dart": "MaterialApp(initialRoute: '/splash', routes: {'/splash': (c) => const SplashScreen(), '/home': (c) => const HomePage()})",
            "lib/home_page.dart": "class HomePage extends StatelessWidget {}\nclass _HomeView extends StatelessWidget {}",
        ])
        #expect(flow.screens.map(\.className) == ["HomePage", "SplashScreen"])
        #expect(links(flow) == ["SplashScreen replaces HomePage"])
    }

    @Test func layoutGivesLinkedScreensTheStartMissesATreeOfTheirOwn() {
        let screens = ["Splash", "Home", "Water", "Add", "Lonely"].map { AppScreen(name: $0, className: $0, file: "lib/\($0).dart") }
        let flow = AppFlow(folder: "/app", screens: screens, links: [
            .init(from: "Splash", to: "Home", kind: .replaces),
            .init(from: "Water", to: "Add", kind: .opens),
        ], start: "Splash")
        #expect(flow.layout == AppFlow.Layout(columns: [["Splash", "Water"], ["Home", "Add"]], unlinked: ["Lonely"]))
    }

    @Test func ignoresCommentedOutNavigationButKeepsUrls() {
        let source = """
        // Navigator.push(context, MaterialPageRoute(builder: (_) => ProfilePage()));
        final url = 'https://example.com'; /* SettingsPage() */
        """
        let stripped = FlowFinder.withoutComments(source)
        #expect(!stripped.contains("ProfilePage"))
        #expect(!stripped.contains("SettingsPage"))
        #expect(stripped.contains("https://example.com"))
    }

    @Test func layoutPutsScreensNothingLeadsToLast() {
        let screens = ["A", "B", "C"].map { AppScreen(name: $0, className: $0, file: "lib/\($0).dart") }
        let flow = AppFlow(folder: "/app", screens: screens, links: [.init(from: "A", to: "B", kind: .opens)], start: "A")
        #expect(flow.layout == AppFlow.Layout(columns: [["A"], ["B"]], unlinked: ["C"]))
        let geometry = FlowGeometry(flow.layout)
        #expect(geometry.frames.count == 3)
        #expect(geometry.unlinkedTop != nil)
    }

    @Test func matchesRoutePathsWithParameters() {
        #expect(RouteTable.path("/user/$id", matches: "/user/:id"))
        #expect(RouteTable.path("/home/details?tab=1", matches: "details"))
        #expect(!RouteTable.path("/user/1/edit", matches: "/user/:id"))
        #expect(!RouteTable.path("/x", matches: "#x"))
        #expect(!RouteTable.path("/home/$id", matches: "/home/edit", strictly: true))
    }
}
