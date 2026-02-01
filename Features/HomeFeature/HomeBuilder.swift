//
//  HomeBuilder.swift
//  Quran
//
//  Created by Afifi, Mohamed on 11/14/20.
//  Copyright © 2020 Quran.com. All rights reserved.
//

import AnnotationsService
import AppDependencies
import FeaturesSupport
import QuranTextKit
import ReadingSelectorFeature
import UIKit

@MainActor
public struct HomeBuilder {
    // MARK: Lifecycle

    public init(container: AppDependencies) {
        self.container = container
    }

    // MARK: Public

    public func build(withListener listener: QuranNavigator) -> UIViewController {
        let lastPageService = LastPageService(persistence: container.lastPagePersistence)
        let textRetriever = QuranTextDataService(
            databasesURL: container.databasesURL,
            quranFileURL: container.quranUthmaniV2Database
        )

        let viewModel = HomeViewModel(
            lastPageService: lastPageService,
            textRetriever: textRetriever,
            navigateToPage: { lastPage in
                listener.navigateTo(page: lastPage, lastPage: lastPage, highlightingSearchAyah: nil)
            },
            navigateToSura: { sura in
                listener.navigateTo(page: sura.page, lastPage: nil, highlightingSearchAyah: nil)
            },
            navigateToQuarter: { quarter in
                listener.navigateTo(page: quarter.page, lastPage: nil, highlightingSearchAyah: nil)
            }
        )
        let viewController = HomeViewController(
            viewModel: viewModel,
            readingSelectorBuilder: ReadingSelectorBuilder(container: container)
        )
        return viewController
    }

    // MARK: Internal

    let container: AppDependencies
}
